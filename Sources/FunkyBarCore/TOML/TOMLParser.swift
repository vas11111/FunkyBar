import Foundation

/// A TOML parser covering the subset the funkybar schema uses.
///
/// Supported: tables, arrays of tables, dotted keys, inline tables, arrays,
/// basic and literal strings (single and multi-line), integers (decimal, hex,
/// octal, binary, with underscore separators), floats, and booleans.
///
/// Deliberately unsupported: date and time values. They are rejected with an
/// explicit diagnostic rather than coerced, since nothing in the schema uses
/// them and a silently misparsed date is worse than a clear failure.
public struct TOMLParser {
    private let chars: [Character]
    private var index: Int = 0
    private var line: Int = 1
    private var column: Int = 1

    private init(_ source: String) {
        // Normalise line endings so column arithmetic stays honest on CRLF files.
        self.chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    /// Parses `source` into a table, or throws the first structural error found.
    public static func parse(_ source: String) throws -> TOMLTable {
        var parser = TOMLParser(source)
        return try parser.run()
    }

    // MARK: - Builders

    private final class TableBuilder {
        var keys: [String] = []
        var values: [String: Entry] = [:]
        var location: SourceLocation
        /// Declared with an explicit `[header]`.
        var isExplicit = false
        /// Came from `{ ... }`; TOML forbids extending an inline table later.
        var isInline = false

        init(location: SourceLocation) { self.location = location }

        func entry(_ key: String) -> Entry? { values[key] }

        func set(_ key: String, _ entry: Entry) {
            if values[key] == nil { keys.append(key) }
            values[key] = entry
        }
    }

    private enum Entry {
        case node(TOMLNode)
        case table(TableBuilder)
        case tableArray([TableBuilder])
    }

    // MARK: - Main loop

    private mutating func run() throws -> TOMLTable {
        let root = TableBuilder(location: SourceLocation(line: 1, column: 1))
        var current = root

        while true {
            skipTrivia()
            guard let c = peek() else { break }

            if c == "[" {
                current = try parseTableHeader(root: root)
            } else {
                try parseKeyValue(into: current)
                try expectLineEnd()
            }
        }

        return freeze(root)
    }

    // MARK: - Table headers

    private mutating func parseTableHeader(root: TableBuilder) throws -> TableBuilder {
        let start = location()
        advance() // consume '['

        let isArray = peek() == "["
        if isArray { advance() }

        skipInlineWhitespace()
        let path = try parseKeyPath()
        skipInlineWhitespace()

        try expect("]", context: isArray ? "array-of-tables header" : "table header")
        if isArray {
            try expect("]", context: "array-of-tables header")
        }
        try expectLineEnd()

        guard !path.isEmpty else {
            throw diagnostic("empty table header", at: start)
        }

        let parent = try resolveParent(of: path, from: root)
        let (key, keyLocation) = path[path.count - 1]

        if isArray {
            switch parent.entry(key) {
            case .none:
                let table = TableBuilder(location: start)
                table.isExplicit = true
                parent.set(key, .tableArray([table]))
                return table

            case .tableArray(var elements):
                let table = TableBuilder(location: start)
                table.isExplicit = true
                elements.append(table)
                parent.set(key, .tableArray(elements))
                return table

            case .table, .node:
                throw diagnostic(
                    "'\(key)' is already defined as a table, so it cannot also be an array of tables",
                    at: keyLocation,
                    hint: "use [[\(key)]] consistently, or rename one of them"
                )
            }
        }

        switch parent.entry(key) {
        case .none:
            let table = TableBuilder(location: start)
            table.isExplicit = true
            parent.set(key, .table(table))
            return table

        case .table(let existing):
            if existing.isExplicit {
                throw diagnostic(
                    "table '\(key)' is defined more than once",
                    at: keyLocation,
                    hint: "first defined at line \(existing.location.line)"
                )
            }
            if existing.isInline {
                throw diagnostic(
                    "'\(key)' was defined as an inline table and cannot be extended",
                    at: keyLocation
                )
            }
            existing.isExplicit = true
            existing.location = start
            return existing

        case .tableArray:
            throw diagnostic(
                "'\(key)' is an array of tables; use [[\(key)]] to add another element",
                at: keyLocation
            )

        case .node:
            throw diagnostic("'\(key)' is already defined as a value", at: keyLocation)
        }
    }

    /// Walks every path segment except the last, creating implicit tables.
    private func resolveParent(
        of path: [(String, SourceLocation)],
        from root: TableBuilder
    ) throws -> TableBuilder {
        var node = root

        for (key, keyLocation) in path.dropLast() {
            switch node.entry(key) {
            case .none:
                let table = TableBuilder(location: keyLocation)
                node.set(key, .table(table))
                node = table

            case .table(let existing):
                if existing.isInline {
                    throw diagnostic(
                        "'\(key)' was defined as an inline table and cannot be extended",
                        at: keyLocation
                    )
                }
                node = existing

            // A header under an array of tables targets its most recent element.
            case .tableArray(let elements):
                guard let last = elements.last else {
                    throw diagnostic("'\(key)' is an empty array of tables", at: keyLocation)
                }
                node = last

            // An inline table is stored as a value node, so distinguish it here
            // rather than reporting the misleading "is a value" message.
            case .node(let existing):
                if case .table = existing.value {
                    throw diagnostic(
                        "'\(key)' was defined as an inline table and cannot be extended",
                        at: keyLocation,
                        hint: "declare it as [\(key)] instead of an inline { ... }"
                    )
                }
                throw diagnostic(
                    "'\(key)' is a value, so it cannot contain a table",
                    at: keyLocation
                )
            }
        }

        return node
    }

    // MARK: - Key/value pairs

    private mutating func parseKeyValue(into table: TableBuilder) throws {
        let path = try parseKeyPath()
        guard !path.isEmpty else {
            throw diagnostic("expected a key", at: location())
        }

        skipInlineWhitespace()
        try expect("=", context: "key/value pair", hint: "keys and values are separated by '='")
        skipInlineWhitespace()

        let node = try parseValue()

        // Dotted keys create intermediate tables implicitly.
        var target = table
        for (key, keyLocation) in path.dropLast() {
            switch target.entry(key) {
            case .none:
                let created = TableBuilder(location: keyLocation)
                target.set(key, .table(created))
                target = created

            case .table(let existing):
                if existing.isInline {
                    throw diagnostic(
                        "'\(key)' was defined as an inline table and cannot be extended",
                        at: keyLocation
                    )
                }
                target = existing

            case .tableArray(let elements):
                guard let last = elements.last else {
                    throw diagnostic("'\(key)' is an empty array of tables", at: keyLocation)
                }
                target = last

            case .node(let existing):
                if case .table = existing.value {
                    throw diagnostic(
                        "'\(key)' was defined as an inline table and cannot be extended",
                        at: keyLocation,
                        hint: "declare it as [\(key)] instead of an inline { ... }"
                    )
                }
                throw diagnostic(
                    "'\(key)' is a value, so it cannot contain a key",
                    at: keyLocation
                )
            }
        }

        let (key, keyLocation) = path[path.count - 1]
        if target.entry(key) != nil {
            throw diagnostic("'\(key)' is defined more than once", at: keyLocation)
        }
        target.set(key, .node(node))
    }

    private mutating func parseKeyPath() throws -> [(String, SourceLocation)] {
        var path: [(String, SourceLocation)] = []

        while true {
            skipInlineWhitespace()
            let start = location()

            guard let c = peek() else {
                throw diagnostic("unexpected end of file while reading a key", at: start)
            }

            let key: String
            if c == "\"" || c == "'" {
                key = try parseQuotedString().0
            } else if isBareKeyCharacter(c) {
                var scalar = ""
                while let ch = peek(), isBareKeyCharacter(ch) {
                    scalar.append(ch)
                    advance()
                }
                key = scalar
            } else {
                throw diagnostic(
                    "unexpected character '\(c)' where a key was expected",
                    at: start,
                    hint: "keys are bare words, or quoted with \" or '"
                )
            }

            path.append((key, start))

            skipInlineWhitespace()
            if peek() == "." {
                advance()
                continue
            }
            return path
        }
    }

    // MARK: - Values

    private mutating func parseValue() throws -> TOMLNode {
        let start = location()

        guard let c = peek() else {
            throw diagnostic("expected a value", at: start)
        }

        switch c {
        case "\"", "'":
            let (text, _) = try parseQuotedString()
            return TOMLNode(.string(text), at: start)

        case "[":
            return try parseArray()

        case "{":
            return try parseInlineTable()

        default:
            return try parseBareValue()
        }
    }

    private mutating func parseArray() throws -> TOMLNode {
        let start = location()
        advance() // '['

        var elements: [TOMLNode] = []

        while true {
            skipTrivia() // arrays may span lines and contain comments
            guard let c = peek() else {
                throw diagnostic("unterminated array", at: start, hint: "expected a closing ']'")
            }

            if c == "]" {
                advance()
                return TOMLNode(.array(elements), at: start)
            }

            elements.append(try parseValue())

            skipTrivia()
            if peek() == "," {
                advance()
                continue
            }
            if peek() == "]" {
                advance()
                return TOMLNode(.array(elements), at: start)
            }
            guard peek() != nil else {
                throw diagnostic("unterminated array", at: start, hint: "expected a closing ']'")
            }

            throw diagnostic(
                "expected ',' or ']' in array",
                at: location(),
                hint: "array elements are separated by commas"
            )
        }
    }

    private mutating func parseInlineTable() throws -> TOMLNode {
        let start = location()
        advance() // '{'

        var table = TOMLTable(location: start)
        var seen = Set<String>()

        skipInlineWhitespace()
        if peek() == "}" {
            advance()
            return TOMLNode(.table(table), at: start)
        }

        while true {
            skipInlineWhitespace()

            let path = try parseKeyPath()
            guard path.count == 1 else {
                throw diagnostic(
                    "dotted keys are not supported inside inline tables",
                    at: path[0].1,
                    hint: "use a nested inline table instead: a = { b = 1 }"
                )
            }
            let (key, keyLocation) = path[0]

            guard seen.insert(key).inserted else {
                throw diagnostic("'\(key)' is defined more than once", at: keyLocation)
            }

            skipInlineWhitespace()
            try expect("=", context: "inline table")
            skipInlineWhitespace()

            table.insert(try parseValue(), for: key)

            skipInlineWhitespace()
            if peek() == "," {
                advance()
                continue
            }
            if peek() == "}" {
                advance()
                return TOMLNode(.table(table), at: start)
            }

            throw diagnostic(
                "expected ',' or '}' in inline table",
                at: location(),
                hint: "inline table entries are separated by commas"
            )
        }
    }

    /// Reads an unquoted token and classifies it as bool, integer or float.
    private mutating func parseBareValue() throws -> TOMLNode {
        let start = location()
        var token = ""

        while let c = peek(), isBareValueCharacter(c) {
            token.append(c)
            advance()
        }

        guard !token.isEmpty else {
            let found = peek().map { "'\($0)'" } ?? "end of file"
            throw diagnostic("expected a value, found \(found)", at: start)
        }

        if token == "true"  { return TOMLNode(.boolean(true), at: start) }
        if token == "false" { return TOMLNode(.boolean(false), at: start) }

        if looksLikeDateTime(token) {
            throw diagnostic(
                "date and time values are not supported",
                at: start,
                hint: "quote it as a string if you need the literal text"
            )
        }

        if let value = parseInteger(token) {
            return TOMLNode(.integer(value), at: start)
        }
        if let value = parseDouble(token) {
            return TOMLNode(.double(value), at: start)
        }

        throw diagnostic(
            "'\(token)' is not a valid value",
            at: start,
            hint: "expected a number, true, false, or a quoted string"
        )
    }

    // MARK: - Strings

    /// Returns the decoded text and whether it was a literal (single-quoted) string.
    private mutating func parseQuotedString() throws -> (String, Bool) {
        let start = location()
        guard let quote = peek() else {
            throw diagnostic("expected a string", at: start)
        }

        let isLiteral = quote == "'"

        // Detect the multi-line form: three identical quote characters.
        if peek(1) == quote && peek(2) == quote {
            advance(); advance(); advance()
            // A newline immediately after the opening delimiter is trimmed.
            if peek() == "\n" { advance() }
            return (try parseMultilineString(quote: quote, isLiteral: isLiteral, start: start), isLiteral)
        }

        advance() // opening quote
        var out = ""

        while true {
            guard let c = peek() else {
                throw diagnostic("unterminated string", at: start)
            }
            if c == "\n" {
                throw diagnostic(
                    "unterminated string",
                    at: start,
                    hint: "a single-quoted string cannot span lines; use triple quotes"
                )
            }
            if c == quote {
                advance()
                return (out, isLiteral)
            }
            if c == "\\" && !isLiteral {
                advance()
                out.append(try parseEscape())
                continue
            }
            out.append(c)
            advance()
        }
    }

    private mutating func parseMultilineString(
        quote: Character,
        isLiteral: Bool,
        start: SourceLocation
    ) throws -> String {
        var out = ""

        while true {
            guard let c = peek() else {
                throw diagnostic("unterminated multi-line string", at: start)
            }

            if c == quote && peek(1) == quote && peek(2) == quote {
                advance(); advance(); advance()
                return out
            }

            if c == "\\" && !isLiteral {
                // A backslash at end of line swallows the newline and following
                // indentation, which is how TOML folds long lines.
                if peek(1) == "\n" {
                    advance()
                    while let ch = peek(), ch == "\n" || ch == " " || ch == "\t" { advance() }
                    continue
                }
                advance()
                out.append(try parseEscape())
                continue
            }

            out.append(c)
            advance()
        }
    }

    private mutating func parseEscape() throws -> Character {
        let start = location()
        guard let c = peek() else {
            throw diagnostic("unterminated escape sequence", at: start)
        }
        advance()

        switch c {
        case "n":  return "\n"
        case "t":  return "\t"
        case "r":  return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "0":  return "\0"
        case "b":  return "\u{08}"
        case "f":  return "\u{0C}"
        case "u":  return try parseUnicodeEscape(digits: 4, start: start)
        case "U":  return try parseUnicodeEscape(digits: 8, start: start)
        default:
            throw diagnostic("unknown escape sequence '\\\(c)'", at: start)
        }
    }

    private mutating func parseUnicodeEscape(digits: Int, start: SourceLocation) throws -> Character {
        var hex = ""
        for _ in 0 ..< digits {
            guard let c = peek(), c.isHexDigit else {
                throw diagnostic("expected \(digits) hex digits in unicode escape", at: start)
            }
            hex.append(c)
            advance()
        }
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw diagnostic("'\(hex)' is not a valid unicode scalar", at: start)
        }
        return Character(scalar)
    }

    // MARK: - Number classification

    private func parseInteger(_ token: String) -> Int? {
        var text = token.replacingOccurrences(of: "_", with: "")

        var sign = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() }
        else if text.hasPrefix("+") { text.removeFirst() }

        guard !text.isEmpty else { return nil }

        let radix: Int
        if text.hasPrefix("0x") { radix = 16; text.removeFirst(2) }
        else if text.hasPrefix("0o") { radix = 8; text.removeFirst(2) }
        else if text.hasPrefix("0b") { radix = 2; text.removeFirst(2) }
        else { radix = 10 }

        guard !text.isEmpty, let magnitude = Int(text, radix: radix) else { return nil }
        return sign * magnitude
    }

    private func parseDouble(_ token: String) -> Double? {
        let text = token.replacingOccurrences(of: "_", with: "")

        switch text {
        case "inf", "+inf": return .infinity
        case "-inf":        return -.infinity
        case "nan", "+nan", "-nan": return .nan
        default: break
        }

        // Reject anything Double(_:) would accept but TOML would not, such as
        // hex float literals.
        guard text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) else { return nil }
        guard !text.lowercased().hasPrefix("0x") else { return nil }
        return Double(text)
    }

    private func looksLikeDateTime(_ token: String) -> Bool {
        if token.contains(":") { return true }
        // 1979-05-27 style: digit-led with an interior dash.
        guard let first = token.first, first.isNumber else { return false }
        return token.dropFirst().contains("-")
    }

    // MARK: - Character classes

    private func isBareKeyCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    private func isBareValueCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || "+-._:".contains(c)
    }

    // MARK: - Cursor

    private func peek(_ offset: Int = 0) -> Character? {
        let i = index + offset
        return i < chars.count ? chars[i] : nil
    }

    private mutating func advance() {
        guard index < chars.count else { return }
        if chars[index] == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }

    private func location() -> SourceLocation {
        SourceLocation(line: line, column: column)
    }

    private mutating func expect(_ c: Character, context: String, hint: String? = nil) throws {
        guard peek() == c else {
            let found = peek().map { "'\($0)'" } ?? "end of file"
            throw diagnostic(
                "expected '\(c)' in \(context), found \(found)",
                at: location(),
                hint: hint
            )
        }
        advance()
    }

    /// Consumes to the end of the current line, rejecting trailing junk.
    private mutating func expectLineEnd() throws {
        skipInlineWhitespace()

        if peek() == "#" {
            while let c = peek(), c != "\n" { advance() }
        }

        guard let c = peek() else { return }
        guard c == "\n" else {
            throw diagnostic(
                "unexpected '\(c)' after the end of this entry",
                at: location(),
                hint: "each key/value pair goes on its own line"
            )
        }
        advance()
    }

    private mutating func skipInlineWhitespace() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }

    /// Skips whitespace, newlines and comments.
    private mutating func skipTrivia() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" {
                advance()
            } else if c == "#" {
                while let ch = peek(), ch != "\n" { advance() }
            } else {
                return
            }
        }
    }

    private func diagnostic(
        _ message: String,
        at location: SourceLocation,
        hint: String? = nil
    ) -> ConfigDiagnostics {
        ConfigDiagnostics([
            ConfigDiagnostic(severity: .error, message: message, location: location, hint: hint)
        ])
    }

    // MARK: - Freeze

    private func freeze(_ builder: TableBuilder) -> TOMLTable {
        var table = TOMLTable(location: builder.location)

        for key in builder.keys {
            guard let entry = builder.values[key] else { continue }
            switch entry {
            case .node(let node):
                table.insert(node, for: key)

            case .table(let child):
                table.insert(TOMLNode(.table(freeze(child)), at: child.location), for: key)

            case .tableArray(let elements):
                let nodes = elements.map { TOMLNode(.table(freeze($0)), at: $0.location) }
                let location = elements.first?.location ?? builder.location
                table.insert(TOMLNode(.array(nodes), at: location), for: key)
            }
        }

        return table
    }
}
