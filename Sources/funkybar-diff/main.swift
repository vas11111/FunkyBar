import AppKit
import Foundation

// Compares two bars inside one screenshot, pixel by pixel.
//
// Every other instrument in this repo compares things both sides *report*:
// geometry from the window server, style from `sketchybar --query`, our own
// layout from `--dump`. Each of those found real bugs, and each was blind to a
// class of bug that leaves all reported values correct: glyphs clipped to their
// ink box, a pen offset applied twice, the whole bar 8pt high. Those are only
// visible in pixels.
//
// So: take a screenshot with sketchybar and funkybar both on screen, and this
// finds every drawn run in each strip and compares their edges.
//
// usage: funkybar-diff <screenshot.png> [--rows <yA> <yB>] [--height 36]

struct Run {
    let start: Double
    let end: Double
    var width: Double { end - start }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("""
    usage: funkybar-diff <screenshot.png> [--rows <yA> <yB>] [--height 36]

    Capture a screenshot showing both bars, then run this. Rows are detected
    automatically unless --rows is given. Coordinates are in points.
    """)
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("cannot read \(arguments[1])")
    exit(1)
}

let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
) else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

/// Retina screenshots are 2x; a 1x capture halves every coordinate.
let scale: Double = width > 2600 ? 2 : 1

@MainActor func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * width + x) * 4
    return (Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
}

/// A bar pill is very dark; the desktop behind it is not.
@MainActor func isPill(_ x: Int, _ y: Int) -> Bool {
    let c = rgb(x, y)
    return c.r < 80 && c.g < 80 && c.b < 80
}

@MainActor func pillCount(inRow y: Int) -> Int {
    var count = 0
    for x in 0 ..< width where isPill(x, y) { count += 1 }
    return count
}

// MARK: - Row detection

@MainActor func detectRows() -> [Int] {
    // A bar row is a thick horizontal band of dark pixels. Density alone is not
    // enough: a screenshot usually includes a dark strip at the very top from
    // the desktop or menu bar, which is dense but only a few rows tall, and
    // treating it as a bar makes the tool compare the wrong two things.
    var dense: [Int] = []
    let threshold = width / 12
    for y in 0 ..< height where pillCount(inRow: y) > threshold { dense.append(y) }
    guard !dense.isEmpty else { return [] }

    var bands: [[Int]] = []
    var current: [Int] = [dense[0]]
    for y in dense.dropFirst() {
        if y - current.last! <= 2 { current.append(y) } else { bands.append(current); current = [y] }
    }
    bands.append(current)

    // A pill is ~24pt tall, so require most of that before believing a band.
    let minimumThickness = Int(14 * scale)
    let bars = bands.filter { $0.count >= minimumThickness }
    guard bars.count >= 2 else {
        return bands.sorted { $0.count > $1.count }.prefix(2)
            .map { $0[$0.count / 2] }.sorted()
    }
    return bars.map { $0[$0.count / 2] }
}

var rows: [Int]
if let index = arguments.firstIndex(of: "--rows"), index + 2 < arguments.count {
    rows = [Int(Double(arguments[index + 1])! * scale), Int(Double(arguments[index + 2])! * scale)]
} else {
    rows = detectRows()
}

guard rows.count >= 2 else {
    print("found \(rows.count) bar row(s); need two. Pass --rows <yA> <yB> in points.")
    exit(1)
}
let (rowA, rowB) = (rows[0], rows[1])

// MARK: - Runs

/// Contiguous spans of pill along one scanline, in points.
@MainActor func runs(inRow y: Int) -> [Run] {
    var out: [Run] = []
    var start = -1
    for x in 0 ..< width {
        if isPill(x, y) {
            if start < 0 { start = x }
        } else if start >= 0 {
            // Ignore slivers from antialiasing between adjacent pills.
            if x - start > Int(4 * scale) {
                out.append(Run(start: Double(start) / scale, end: Double(x) / scale))
            }
            start = -1
        }
    }
    if start >= 0 { out.append(Run(start: Double(start) / scale, end: Double(width) / scale)) }
    return out
}

let runsA = runs(inRow: rowA)
let runsB = runs(inRow: rowB)

print("row A (sketchybar) at y=\(Double(rowA)/scale)pt: \(runsA.count) pills")
print("row B (funkybar)   at y=\(Double(rowB)/scale)pt: \(runsB.count) pills\n")

print("   pill   sketchybar x..x+w        funkybar x..x+w          dx      dw")
print("   " + String(repeating: "-", count: 68))

var worstX = 0.0
var worstW = 0.0
var matched = 0
var unmatchedA: [Int] = []
var pool = Array(runsB.enumerated())

for (index, a) in runsA.enumerated() {
    // Nearest start wins, within a tolerance. Index alignment breaks as soon
    // as one row has an extra run, which turns every later comparison into
    // noise.
    let best = pool.min { abs($0.element.start - a.start) < abs($1.element.start - a.start) }
    guard let best, abs(best.element.start - a.start) < 8 else {
        unmatchedA.append(index + 1)
        continue
    }
    pool.removeAll { $0.offset == best.offset }
    let b = best.element

    matched += 1
    let dx = b.start - a.start
    let dw = b.width - a.width
    worstX = max(worstX, abs(dx))
    worstW = max(worstW, abs(dw))
    let flag = (abs(dx) >= 1 || abs(dw) >= 1) ? "  <-" : ""
    print(String(format: "   %2d     %7.1f..%-7.1f (%5.1f)   %7.1f..%-7.1f (%5.1f)   %+5.1f   %+5.1f%@",
                 index + 1, a.start, a.end, a.width, b.start, b.end, b.width, dx, dw, flag as NSString))
}

if !unmatchedA.isEmpty {
    print("\n   sketchybar runs with no counterpart: \(unmatchedA.map(String.init).joined(separator: ", "))")
}
if !pool.isEmpty {
    let extras = pool.map { String(format: "%.1f..%.1f", $0.element.start, $0.element.end) }
    print("   funkybar runs with no counterpart: \(extras.joined(separator: ", "))")
}
print("   matched \(matched)/\(runsA.count)")

print(String(format: "\n   worst |dx| = %.1fpt   worst |dw| = %.1fpt", worstX, worstW))

// MARK: - Vertical extents

/// Top and bottom of the pill band around a scanline, in points.
@MainActor func verticalExtent(around y: Int, atX x: Int) -> (top: Double, bottom: Double)? {
    guard isPill(x, y) else { return nil }
    var top = y, bottom = y
    while top > 0, isPill(x, top - 1) { top -= 1 }
    while bottom < height - 1, isPill(x, bottom + 1) { bottom += 1 }
    return (Double(top) / scale, Double(bottom + 1) / scale)
}

if let first = runsA.first, let firstB = runsB.first {
    let xA = Int((first.start + first.width / 2) * scale)
    let xB = Int((firstB.start + firstB.width / 2) * scale)
    if let a = verticalExtent(around: rowA, atX: xA), let b = verticalExtent(around: rowB, atX: xB) {
        print(String(format: "\n   pill height: sketchybar %.1fpt   funkybar %.1fpt   (%+.1f)",
                     a.bottom - a.top, b.bottom - b.top, (b.bottom - b.top) - (a.bottom - a.top)))
        print(String(format: "   row spacing: sketchybar top %.1f, funkybar top %.1f", a.top, b.top))
    }
}
