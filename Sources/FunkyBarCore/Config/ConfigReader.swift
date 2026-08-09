import Foundation

/// Accumulates diagnostics across a whole decode pass.
///
/// Validation collects rather than throwing on the first problem, so a user
/// fixing a config sees every error in one run instead of one per attempt.
public final class DiagnosticSink {
    public private(set) var diagnostics = ConfigDiagnostics()

    public init() {}

    public func error(_ message: String, at location: SourceLocation, hint: String? = nil) {
        diagnostics.error(message, at: location, hint: hint)
    }

    public func warn(_ message: String, at location: SourceLocation, hint: String? = nil) {
        diagnostics.warn(message, at: location, hint: hint)
    }

    public var hasErrors: Bool { diagnostics.hasErrors }
}

/// A typed, diagnostic-collecting view over one TOML table.
///
/// Every accessor records a located error on a type mismatch and returns nil,
/// so decoding continues and reports everything wrong at once.
public struct ConfigReader {
    public let table: TOMLTable
    /// Dotted path used in messages, e.g. `item[2].icon`.
    public let path: String
    public let sink: DiagnosticSink

    public init(table: TOMLTable, path: String, sink: DiagnosticSink) {
        self.table = table
        self.path = path
        self.sink = sink
    }

    public var location: SourceLocation { table.location }

    private func label(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    public func has(_ key: String) -> Bool { table[key] != nil }

    /// Type probes that record nothing.
    ///
    /// Several keys accept either a scalar or a table (`icon = "›"` versus
    /// `[item.icon]`). Probing with `child(_:)` first would record a spurious
    /// "should be a table" error on the scalar form, so branch on these.
    public func isTable(_ key: String) -> Bool {
        if case .table = table[key]?.value { return true }
        return false
    }

    public func isString(_ key: String) -> Bool {
        if case .string = table[key]?.value { return true }
        return false
    }

    private func mismatch(_ key: String, expected: String, node: TOMLNode) {
        sink.error(
            "'\(label(key))' should be \(expected), found \(node.value.typeName)",
            at: node.location
        )
    }

    // MARK: - Scalars

    public func string(_ key: String) -> String? {
        guard let node = table[key] else { return nil }
        guard case .string(let value) = node.value else {
            mismatch(key, expected: "a string", node: node)
            return nil
        }
        return value
    }

    public func bool(_ key: String) -> Bool? {
        guard let node = table[key] else { return nil }
        guard case .boolean(let value) = node.value else {
            mismatch(key, expected: "true or false", node: node)
            return nil
        }
        return value
    }

    public func int(_ key: String) -> Int? {
        guard let node = table[key] else { return nil }
        switch node.value {
        case .integer(let value):
            return value
        case .double(let value) where value == value.rounded():
            // Int(Double) is non-failable and traps out of range, so a config
            // saying `max_chars = 1e20` would abort the daemon rather than
            // report a problem.
            guard value >= -9.2e18, value <= 9.2e18 else {
                sink.error(
                    "'\(label(key))' is too large to be a whole number",
                    at: node.location,
                    hint: "expected a value between \(Int.min) and \(Int.max)"
                )
                return nil
            }
            return Int(value)
        default:
            mismatch(key, expected: "a whole number", node: node)
            return nil
        }
    }

    public func double(_ key: String) -> Double? {
        guard let node = table[key] else { return nil }
        switch node.value {
        case .integer(let value): return Double(value)
        case .double(let value):  return value
        default:
            mismatch(key, expected: "a number", node: node)
            return nil
        }
    }

    /// A non-negative number, rejecting negatives with a specific message.
    public func length(_ key: String) -> Double? {
        guard let value = double(key) else { return nil }
        guard value >= 0 else {
            sink.error(
                "'\(label(key))' must not be negative, got \(value)",
                at: table[key]?.location ?? location
            )
            return nil
        }
        return value
    }

    /// Seconds, accepting a bare number or a `"5s"` / `"250ms"` / `"2m"` string.
    public func duration(_ key: String) -> Double? {
        guard let node = table[key] else { return nil }

        switch node.value {
        case .integer(let value): return Double(value)
        case .double(let value):  return value
        case .string(let text):
            guard let seconds = ConfigReader.parseDuration(text) else {
                sink.error(
                    "'\(label(key))' is not a valid duration: \"\(text)\"",
                    at: node.location,
                    hint: "use a number of seconds, or a suffixed string like \"5s\", \"250ms\", \"2m\""
                )
                return nil
            }
            return seconds
        default:
            mismatch(key, expected: "a duration", node: node)
            return nil
        }
    }

    public static func parseDuration(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(suffix: String, scale: Double)] = [
            ("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600),
        ]
        for (suffix, scale) in units where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count)
            guard let value = Double(number), value >= 0 else { return nil }
            return value * scale
        }
        guard let value = Double(trimmed), value >= 0 else { return nil }
        return value
    }

    // MARK: - Compound values

    public func color(_ key: String) -> Color? {
        guard let node = table[key] else { return nil }
        guard case .string(let text) = node.value else {
            mismatch(key, expected: "a colour string", node: node)
            return nil
        }
        switch Color.parse(text) {
        case .success(let color):
            return color
        case .failure(let failure):
            sink.error(
                "'\(label(key))' is not a valid colour: \(failure.message)",
                at: node.location,
                hint: failure.hint
            )
            return nil
        }
    }

    public func font(_ key: String) -> FontSpec? {
        guard let node = table[key] else { return nil }

        switch node.value {
        case .string(let text):
            // SketchyBar's "Family:Style:Size" shorthand.
            guard let font = FontSpec.parse(text) else {
                sink.error(
                    "'\(label(key))' is not a valid font: \"\(text)\"",
                    at: node.location,
                    hint: "use \"Family:Style:Size\" or a table { family, style, size }"
                )
                return nil
            }
            return font

        case .table(let child):
            let reader = ConfigReader(table: child, path: label(key), sink: sink)
            reader.warnUnknownKeys(["family", "style", "size"])
            guard let family = reader.string("family") else {
                sink.error("'\(label(key))' needs a 'family'", at: node.location)
                return nil
            }
            var font = FontSpec(family: family)
            if let style = reader.string("style") { font.style = style }
            if let size = reader.length("size") { font.size = size }
            return font

        default:
            mismatch(key, expected: "a font", node: node)
            return nil
        }
    }

    /// Accepts a number (all sides) or a table of named sides.
    public func insets(_ key: String) -> Insets? {
        guard let node = table[key] else { return nil }

        switch node.value {
        case .integer, .double:
            guard let value = double(key) else { return nil }
            return Insets(all: value)

        case .table(let child):
            let reader = ConfigReader(table: child, path: label(key), sink: sink)
            reader.warnUnknownKeys(["top", "bottom", "left", "right", "leading", "trailing",
                                    "horizontal", "vertical", "all"])
            var insets = Insets()
            if let all = reader.double("all") { insets = Insets(all: all) }
            if let h = reader.double("horizontal") { insets.leading = h; insets.trailing = h }
            if let v = reader.double("vertical") { insets.top = v; insets.bottom = v }
            if let value = reader.double("top") { insets.top = value }
            if let value = reader.double("bottom") { insets.bottom = value }
            if let value = reader.double("left") ?? reader.double("leading") { insets.leading = value }
            if let value = reader.double("right") ?? reader.double("trailing") { insets.trailing = value }
            return insets

        default:
            mismatch(key, expected: "a number or a table of sides", node: node)
            return nil
        }
    }

    public func offset(_ key: String) -> Offset? {
        guard let node = table[key] else { return nil }
        guard case .table(let child) = node.value else {
            mismatch(key, expected: "a table { x, y }", node: node)
            return nil
        }
        let reader = ConfigReader(table: child, path: label(key), sink: sink)
        reader.warnUnknownKeys(["x", "y"])
        return Offset(x: reader.double("x") ?? 0, y: reader.double("y") ?? 0)
    }

    // MARK: - Enums

    public func enumeration<T: RawRepresentable & CaseIterable>(_ key: String, as type: T.Type) -> T?
    where T.RawValue == String {
        guard let text = string(key) else { return nil }
        guard let value = T(rawValue: text) else {
            let options = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            sink.error(
                "'\(label(key))' is not one of the allowed values: \"\(text)\"",
                at: table[key]?.location ?? location,
                hint: "expected one of \(options)"
            )
            return nil
        }
        return value
    }

    // MARK: - Collections

    public func strings(_ key: String) -> [String]? {
        guard let node = table[key] else { return nil }
        guard case .array(let elements) = node.value else {
            mismatch(key, expected: "an array of strings", node: node)
            return nil
        }
        var out: [String] = []
        for element in elements {
            guard case .string(let text) = element.value else {
                sink.error(
                    "'\(label(key))' should contain only strings, found \(element.value.typeName)",
                    at: element.location
                )
                continue
            }
            out.append(text)
        }
        return out
    }

    public func ints(_ key: String) -> [Int]? {
        guard let node = table[key] else { return nil }
        guard case .array(let elements) = node.value else {
            mismatch(key, expected: "an array of numbers", node: node)
            return nil
        }
        var out: [Int] = []
        for element in elements {
            guard case .integer(let value) = element.value else {
                sink.error(
                    "'\(label(key))' should contain only whole numbers, found \(element.value.typeName)",
                    at: element.location
                )
                continue
            }
            out.append(value)
        }
        return out
    }

    /// A nested table.
    public func child(_ key: String) -> ConfigReader? {
        guard let node = table[key] else { return nil }
        guard case .table(let child) = node.value else {
            mismatch(key, expected: "a table", node: node)
            return nil
        }
        return ConfigReader(table: child, path: label(key), sink: sink)
    }

    /// An array of tables, as produced by `[[key]]`.
    public func children(_ key: String) -> [ConfigReader] {
        guard let node = table[key] else { return [] }
        guard case .array(let elements) = node.value else {
            mismatch(key, expected: "an array of tables", node: node)
            return []
        }
        return elements.enumerated().compactMap { index, element in
            guard case .table(let child) = element.value else {
                sink.error(
                    "'\(label(key))' should contain only tables, found \(element.value.typeName)",
                    at: element.location
                )
                return nil
            }
            return ConfigReader(table: child, path: "\(label(key))[\(index)]", sink: sink)
        }
    }

    // MARK: - Typo detection

    /// Warns about keys the schema does not know, with a "did you mean" when a
    /// close match exists. This is the main defence against silent typos.
    public func warnUnknownKeys(_ allowed: Set<String>) {
        for (key, node) in table.entries where !allowed.contains(key) {
            let hint = ConfigReader.closestMatch(to: key, in: allowed).map { "did you mean '\($0)'?" }
            sink.warn("unknown key '\(label(key))'", at: node.location, hint: hint)
        }
    }

    static func closestMatch(to key: String, in candidates: Set<String>) -> String? {
        var best: (name: String, distance: Int)?
        // Only suggest when the edit distance is small relative to the word.
        let threshold = max(2, key.count / 3)

        for candidate in candidates.sorted() {
            let distance = editDistance(key, candidate)
            guard distance <= threshold else { continue }
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.name
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
