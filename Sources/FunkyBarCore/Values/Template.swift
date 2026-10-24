import Foundation

/// A tiny interpolation template: `{field}` substitutes a provider value,
/// `{{` and `}}` escape literal braces.
///
/// Templates are parsed once at config load and rendered on every provider
/// update, so rendering allocates only the output string.
///
/// This is deliberately separate from theme tokens (`$name`), which are
/// substituted at load time and never appear at render time. Keeping the two
/// syntaxes distinct is what makes `label = "${price}"` unambiguous: the `$`
/// is literal because the value is not *exactly* a token reference, and
/// `{price}` interpolates.
public struct Template: Equatable, Hashable, Sendable {
    public enum Segment: Equatable, Hashable, Sendable {
        case literal(String)
        case field(String)
    }

    public let segments: [Segment]
    public let source: String
    /// Pre-rendered output when there are no fields.
    ///
    /// This holds the *unescaped* text, so `{{x}}` renders as `{x}`. Returning
    /// `source` here instead would leak the escape syntax into the bar.
    private let constantValue: String?

    public init(_ source: String) {
        let segments = Template.scan(source)
        self.source = source
        self.segments = segments

        let isConstant = segments.allSatisfy { if case .literal = $0 { true } else { false } }
        self.constantValue = isConstant
            ? segments.reduce(into: "") { out, segment in
                if case .literal(let text) = segment { out += text }
            }
            : nil
    }

    /// True when the template has no fields, so its output never changes.
    public var isConstant: Bool { constantValue != nil }

    /// Field names referenced, in order of first appearance.
    public var fields: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for case .field(let name) in segments where seen.insert(name).inserted {
            out.append(name)
        }
        return out
    }

    /// Renders with `values`. An unknown field renders as empty rather than
    /// failing: a bar that loses one label is better than a bar that dies.
    public func render(_ values: [String: String]) -> String {
        if let constantValue { return constantValue }
        var out = ""
        for segment in segments {
            switch segment {
            case .literal(let text): out += text
            case .field(let name):   out += values[name] ?? ""
            }
        }
        return out
    }

    private static func scan(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var literal = ""
        let chars = Array(source)
        var i = 0

        func flushLiteral() {
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "{" {
                if i + 1 < chars.count && chars[i + 1] == "{" {
                    literal.append("{")
                    i += 2
                    continue
                }
                // Scan to the closing brace. An unterminated brace is treated
                // as a literal so a stray '{' in a label cannot break the bar.
                var j = i + 1
                var name = ""
                while j < chars.count && chars[j] != "}" {
                    name.append(chars[j])
                    j += 1
                }
                if j < chars.count {
                    flushLiteral()
                    segments.append(.field(name.trimmingCharacters(in: .whitespaces)))
                    i = j + 1
                } else {
                    literal.append(c)
                    i += 1
                }
                continue
            }

            if c == "}" && i + 1 < chars.count && chars[i + 1] == "}" {
                literal.append("}")
                i += 2
                continue
            }

            literal.append(c)
            i += 1
        }

        flushLiteral()
        return segments
    }
}

extension Template: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
