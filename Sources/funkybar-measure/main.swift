import AppKit
import Foundation

// Compares funkybar's on-screen geometry against sketchybar's, exactly.
//
// The trick is that sketchybar creates one window per bar item, and window
// *bounds* are readable from the window server without any permission (only
// window *contents* need a Screen Recording grant). So sketchybar's own
// architecture hands us pixel-accurate ground truth for every item it draws,
// which beats reading its config and re-deriving what it ought to be.
//
// funkybar's side comes from `funkybard --dump`, whose frames are the exact
// rects handed to the layer tree.
//
// usage: funkybar-measure [--funkybar-y N] [--sketchybar-y N]

struct Rect {
    let x: Double
    let width: Double
    var right: Double { x + width }
}

// MARK: - sketchybar, via the window server

func sketchybarRects(stripY: Double, screenWidth: Double) -> [Rect] {
    guard let info = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    return info.compactMap { window -> Rect? in
        guard (window[kCGWindowOwnerName as String] as? String) == "sketchybar",
              (window[kCGWindowIsOnscreen as String] as? Bool) == true,
              let dict = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }

        // One display's strip only. Items parked off-screen sit at -9999.
        guard abs(rect.minY - stripY) < 1, rect.minX > -100, rect.minX < 5000 else { return nil }
        // Drop the bar's own backing window, which spans the whole display and
        // corresponds to nothing in funkybar's per-item list.
        guard rect.width < screenWidth * 0.9 else { return nil }
        return Rect(x: rect.minX, width: rect.width)
    }
    .sorted { $0.x < $1.x }
}

// MARK: - funkybar, via --dump

struct DumpItem {
    let id: String
    let rect: Rect
    let detail: String
}

func funkybarDump(configPath: String) -> [DumpItem] {
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("funkybard")

    let process = Process()
    process.executableURL = binary
    process.arguments = ["--config", configPath, "--dump"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do { try process.run() } catch {
        FileHandle.standardError.write(Data("cannot run \(binary.path): \(error)\n".utf8))
        return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    var out: [DumpItem] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let text = String(line)
        guard let xRange = text.range(of: #"x=(-?\d+)"#, options: .regularExpression),
              let wRange = text.range(of: #"w=(\d+)"#, options: .regularExpression)
        else { continue }

        let x = Double(text[xRange].dropFirst(2)) ?? 0
        let w = Double(text[wRange].dropFirst(2)) ?? 0

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let id = trimmed.hasPrefix("[")
            ? String(trimmed.dropFirst().prefix(while: { $0 != "]" }))
            : String(trimmed.prefix(while: { !$0.isWhitespace }))

        let detail = text.range(of: "icon=").map { String(text[$0.lowerBound...]) }
            ?? text.range(of: "label=").map { String(text[$0.lowerBound...]) }
            ?? ""
        out.append(DumpItem(id: id, rect: Rect(x: x, width: w), detail: String(detail.prefix(34))))
    }
    return out.sorted { $0.rect.x < $1.rect.x }
}

// MARK: - Report

func argument(_ name: String, default fallback: Double) -> Double {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count,
          let value = Double(CommandLine.arguments[index + 1])
    else { return fallback }
    return value
}

let configPath = CommandLine.arguments.firstIndex(of: "--config").map {
    CommandLine.arguments[$0 + 1]
} ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/funkybar/funkybar.toml")

let screenWidth = NSScreen.screens
    .max(by: { $0.frame.width < $1.frame.width })?.frame.width ?? 3000
let sketchy = sketchybarRects(stripY: argument("--sketchybar-y", default: 4), screenWidth: Double(screenWidth))
let funky = funkybarDump(configPath: configPath)

guard !sketchy.isEmpty else {
    print("no sketchybar windows found on that strip. Is it running?")
    print("(pass --sketchybar-y N if its bar is not at y=4)")
    exit(1)
}
guard !funky.isEmpty else {
    print("funkybard --dump produced no frames. Build it first: swift build -c release")
    exit(1)
}

print("sketchybar: \(sketchy.count) item windows   funkybar: \(funky.count) frames\n")

// Rank alignment is wrong when the two bars differ structurally: sketchybar
// has a spacer item where funkybar uses a group margin, so one extra rect
// shifts everything after it. Match greedily on nearest position and size
// instead, and report what stayed unmatched rather than silently pairing it.
struct Match {
    let item: DumpItem
    let other: Rect?
}

var remaining = Array(sketchy.enumerated())
var matches: [Match] = []

for item in funky {
    let best = remaining.min { a, b in
        let costA = abs(a.element.x - item.rect.x) + abs(a.element.width - item.rect.width)
        let costB = abs(b.element.x - item.rect.x) + abs(b.element.width - item.rect.width)
        return costA < costB
    }
    guard let best else {
        matches.append(Match(item: item, other: nil))
        continue
    }
    let cost = abs(best.element.x - item.rect.x) + abs(best.element.width - item.rect.width)
    // 40pt of combined error means these are not the same element.
    if cost < 40 {
        remaining.removeAll { $0.offset == best.offset }
        matches.append(Match(item: item, other: best.element))
    } else {
        matches.append(Match(item: item, other: nil))
    }
}

print("  \("item".padding(toLength: 18, withPad: " ", startingAt: 0))"
      + "  \("funkybar x/w".padding(toLength: 17, withPad: " ", startingAt: 0))"
      + "  \("sketchybar x/w".padding(toLength: 17, withPad: " ", startingAt: 0))"
      + "   dx     dw")
print("  " + String(repeating: "-", count: 76))

var worstX = 0.0
var worstW = 0.0
var matched = 0

for match in matches {
    let mine = String(format: "%7.1f %8.1f", match.item.rect.x, match.item.rect.width)
    guard let other = match.other else {
        print("  \(match.item.id.padding(toLength: 18, withPad: " ", startingAt: 0))"
              + "  \(mine.padding(toLength: 17, withPad: " ", startingAt: 0))"
              + "  \("(no match)".padding(toLength: 17, withPad: " ", startingAt: 0))")
        continue
    }
    matched += 1
    let dx = match.item.rect.x - other.x
    let dw = match.item.rect.width - other.width
    worstX = max(worstX, abs(dx))
    worstW = max(worstW, abs(dw))

    let theirs = String(format: "%7.1f %8.1f", other.x, other.width)
    let flag = (abs(dx) >= 1 || abs(dw) >= 1) ? "  <-" : ""
    print("  \(match.item.id.padding(toLength: 18, withPad: " ", startingAt: 0))"
          + "  \(mine.padding(toLength: 17, withPad: " ", startingAt: 0))"
          + "  \(theirs.padding(toLength: 17, withPad: " ", startingAt: 0))"
          + "  \(String(format: "%+5.1f  %+5.1f", dx, dw))\(flag)")
}

print("\n  matched \(matched)/\(funky.count)   worst |dx| = \(String(format: "%.1f", worstX))pt"
      + "   worst |dw| = \(String(format: "%.1f", worstW))pt")

if !remaining.isEmpty {
    let extras = remaining.map { String(format: "x=%.0f w=%.0f", $0.element.x, $0.element.width) }
    print("  sketchybar rects with no funkybar counterpart: \(extras.joined(separator: ", "))")
}
