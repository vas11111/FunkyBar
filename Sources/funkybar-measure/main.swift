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


// MARK: - Style comparison

func describeAny(_ value: Any?) -> String {
    guard let value else { return "-" }
    if let flag = value as? Bool { return flag ? "on" : "off" }
    if let text = value as? String { return text }
    if let number = value as? NSNumber {
        // NSNumber hides Bool; "on"/"off" only if it came from sketchybar.
        let double = Double(truncating: number)
        return double == double.rounded() ? String(format: "%.0f", double) : String(double)
    }
    return "\(value)"
}

/// The bar-level settings funkybar can state, keyed by sketchybar's names.
func barSettings(configPath: String) -> [String: Any]? {
    guard let source = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }

    // Read straight from the TOML rather than adding another dump mode; these
    // are literals, not computed values.
    var out: [String: Any] = ["font_smoothing": "off", "y_offset": 0.0, "height": 36.0]
    var inBar = false
    for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { inBar = line == "[bar]"; continue }
        guard inBar, let equals = line.firstIndex(of: "=") else { continue }
        let key = String(line[line.startIndex ..< equals]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)

        switch key {
        case "height":         out["height"] = Double(value) ?? 36
        case "font_smoothing": out["font_smoothing"] = value == "true" ? "on" : "off"
        case "sticky":         out["sticky"] = value == "true" ? "on" : "off"
        case "blur_radius":    out["blur_radius"] = Double(value) ?? 0
        case "offset":
            if let range = value.range(of: #"y\s*=\s*(-?[\d.]+)"#, options: .regularExpression) {
                out["y_offset"] = Double(value[range].split(separator: "=")[1]
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        default: break
        }
    }
    return out
}

// Geometry is only half the story: identical rects can still differ in colour,
// font or corner radius. `sketchybar --query` reports all of those, so the same
// ground-truth trick works for style.

func sketchybarQuery(_ name: String) -> [String: Any]? {
    for binary in ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"] {
        guard FileManager.default.isExecutableFile(atPath: binary) else { continue }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--query", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { continue }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    return nil
}

/// funkybar uses `.` where sketchybarrc used `_` for repeated items.
func sketchybarName(for id: String) -> String {
    id.replacingOccurrences(of: "meter.", with: "meter_")
}

/// `0xaarrggbb` -> `#aarrggbb`, so the two sides are directly comparable.
func normaliseColor(_ raw: Any?) -> String? {
    guard let text = raw as? String, text.lowercased().hasPrefix("0x") else { return nil }
    // sketchybar prints 0x0 for fully transparent; pad so both sides are
    // 8 hex digits and comparable as strings.
    let digits = String(text.dropFirst(2)).lowercased()
    return "#" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
}

func normaliseFont(_ raw: Any?) -> String? {
    guard let text = raw as? String else { return nil }
    // sketchybar reports "Family:Style:14.00"; we emit "Family:Style:14.0".
    let parts = text.split(separator: ":")
    guard parts.count == 3, let size = Double(parts[2]) else { return text }
    return "\(parts[0]):\(parts[1]):\(size)"
}

guard let jsonData = { () -> Data? in
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().appendingPathComponent("funkybard")
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--config", configPath, "--dump-json"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}(), let mine = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]] else {
    print("\n(style comparison skipped: --dump-json produced nothing)")
    exit(0)
}

// Bar-level properties were not compared at all until font_smoothing turned
// out to differ. A bar can match pixel-for-pixel on every item rect and still
// render wrong if the context it draws into is configured differently.
if let theirBar = sketchybarQuery("bar"), let ourBar = barSettings(configPath: configPath) {
    print("\n  bar settings")
    print("  " + String(repeating: "-", count: 76))
    var barIssues = 0
    for (key, ours) in ourBar.sorted(by: { $0.key < $1.key }) {
        guard let theirs = theirBar[key] else { continue }
        let a = describeAny(ours)
        let b = describeAny(theirs)
        if a != b {
            barIssues += 1
            print("      \(key.padding(toLength: 18, withPad: " ", startingAt: 0)) ours=\(a)   sketchybar=\(b)")
        }
    }
    if barIssues == 0 { print("      all compared bar settings match") }
}

print("\n  style differences (blank means every compared property matches)")
print("  " + String(repeating: "-", count: 76))

var styleIssues = 0

for entry in mine {
    guard let id = entry["id"] as? String else { continue }
    guard let theirs = sketchybarQuery(sketchybarName(for: id)) else { continue }

    let icon = theirs["icon"] as? [String: Any] ?? [:]
    let label = theirs["label"] as? [String: Any] ?? [:]
    let background = (theirs["geometry"] as? [String: Any])?["background"] as? [String: Any] ?? [:]

    var rows: [String] = []

    /// Compares by value, not by description. JSONSerialization turns `true`
    /// into NSNumber(1) and `1` into `1.0`, so comparing rendered strings
    /// reports differences that do not exist.
    func compare(_ property: String, _ ours: Any?, _ other: Any?) {
        func describe(_ value: Any?) -> String {
            guard let value else { return "-" }
            if let number = value as? NSNumber {
                let double = Double(truncating: number)
                return double == double.rounded() ? String(format: "%.0f", double) : String(double)
            }
            return "\(value)"
        }

        let equal: Bool
        switch (ours, other) {
        case let (a as Bool, b as Bool):
            equal = a == b
        case let (a as NSNumber, b as NSNumber):
            equal = abs(Double(truncating: a) - Double(truncating: b)) < 0.01
        case let (a as String, b as String):
            equal = a == b
        case (nil, nil):
            equal = true
        default:
            equal = describe(ours) == describe(other)
        }
        guard !equal else { return }
        rows.append("      \(property.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                    + "ours=\(describe(ours))   sketchybar=\(describe(other))")
    }

    if (entry["kind"] as? String) == "item" {
        // Only compare text properties that are actually drawn on both sides.
        if (entry["icon_drawing"] as? Bool) == true, (icon["drawing"] as? String) == "on" {
            compare("icon.text", entry["icon"], icon["value"])
            compare("icon.color", entry["icon_color"], normaliseColor(icon["color"]))
            compare("icon.font", entry["icon_font"], normaliseFont(icon["font"]))
        } else if (entry["icon_drawing"] as? Bool) != ((icon["drawing"] as? String) == "on") {
            compare("icon.drawing", entry["icon_drawing"] as? Bool, (icon["drawing"] as? String) == "on")
        }

        if (entry["label_drawing"] as? Bool) == true, (label["drawing"] as? String) == "on" {
            compare("label.color", entry["label_color"], normaliseColor(label["color"]))
            compare("label.font", entry["label_font"], normaliseFont(label["font"]))
        }
    }

    let theirBackgroundOn = (background["drawing"] as? String) == "on"
    compare("bg.drawing", entry["bg_drawing"] as? Bool, theirBackgroundOn)
    if (entry["bg_drawing"] as? Bool) == true, theirBackgroundOn {
        compare("bg.color", entry["bg_color"], normaliseColor(background["color"]))
        compare("bg.border", entry["bg_border"], normaliseColor(background["border_color"]))
        compare("bg.border_w", entry["bg_border_w"], (background["border_width"] as? NSNumber).map { Double(truncating: $0) })
        compare("bg.radius", entry["bg_radius"], (background["corner_radius"] as? NSNumber).map { Double(truncating: $0) })
        compare("bg.height", entry["bg_h"], (background["height"] as? NSNumber).map { Double(truncating: $0) })
    }

    if !rows.isEmpty {
        styleIssues += 1
        print("    \(id)")
        rows.forEach { print($0) }
    }
}

print("\n  \(styleIssues) item(s) with style differences")
