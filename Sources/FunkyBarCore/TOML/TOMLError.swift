import Foundation

/// A diagnostic that can point at a specific line and column of a source file.
///
/// Rendering carries the offending source line and a caret, because a config
/// error the user cannot locate is barely better than no error at all.
public struct ConfigDiagnostic: Error, Sendable, Equatable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let message: String
    public let location: SourceLocation
    /// Optional second line of explanation, shown under the caret.
    public let hint: String?

    public init(
        severity: Severity = .error,
        message: String,
        location: SourceLocation,
        hint: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.location = location
        self.hint = hint
    }

    /// Renders in the shape a compiler would use:
    ///
    /// ```
    /// funkybar.toml:12:8: error: expected '=' after key
    ///    12 | height 36
    ///       |        ^
    ///       = hint: keys and values are separated by '='
    /// ```
    public func render(path: String?, source: String?) -> String {
        let file = path ?? "<config>"
        var out = "\(file):\(location.line):\(location.column): \(severity.rawValue): \(message)\n"

        if let source, location.line > 0 {
            let lines = source.components(separatedBy: "\n")
            guard location.line <= lines.count else { return out + hintBlock(gutterWidth: 2) }

            let text = lines[location.line - 1]
            let number = String(location.line)
            let gutter = String(repeating: " ", count: number.count)

            out += "\(gutter) |\n"
            out += "\(number) | \(text)\n"

            // Count in characters so multi-byte glyphs (nerd font icons) do not
            // push the caret off target.
            let pad = String(repeating: " ", count: max(0, location.column - 1))
            out += "\(gutter) | \(pad)^\n"
            out += hintBlock(gutterWidth: number.count)
        } else {
            out += hintBlock(gutterWidth: 2)
        }

        return out
    }

    private func hintBlock(gutterWidth: Int) -> String {
        guard let hint else { return "" }
        let gutter = String(repeating: " ", count: gutterWidth)
        // The "hint:" label lives here rather than in every call site.
        return "\(gutter) = hint: \(hint)\n"
    }
}

/// A collection of diagnostics from one parse or validation pass.
///
/// Validation collects rather than throwing on the first problem, so a user
/// fixing a config sees every error in one run instead of one per attempt.
public struct ConfigDiagnostics: Error, Sendable {
    public private(set) var items: [ConfigDiagnostic] = []

    public init(_ items: [ConfigDiagnostic] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var errors: [ConfigDiagnostic] { items.filter { $0.severity == .error } }
    public var warnings: [ConfigDiagnostic] { items.filter { $0.severity == .warning } }
    public var hasErrors: Bool { items.contains { $0.severity == .error } }

    public mutating func add(_ diagnostic: ConfigDiagnostic) {
        items.append(diagnostic)
    }

    public mutating func error(_ message: String, at location: SourceLocation, hint: String? = nil) {
        add(ConfigDiagnostic(severity: .error, message: message, location: location, hint: hint))
    }

    public mutating func warn(_ message: String, at location: SourceLocation, hint: String? = nil) {
        add(ConfigDiagnostic(severity: .warning, message: message, location: location, hint: hint))
    }

    public mutating func merge(_ other: ConfigDiagnostics) {
        items.append(contentsOf: other.items)
    }

    /// Sorted by position so output reads top-to-bottom through the file.
    public func render(path: String?, source: String?) -> String {
        items
            .sorted { ($0.location.line, $0.location.column) < ($1.location.line, $1.location.column) }
            .map { $0.render(path: path, source: source) }
            .joined(separator: "\n")
    }
}
