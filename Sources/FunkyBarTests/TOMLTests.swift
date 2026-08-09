import Foundation
import TestKit
import FunkyBarCore

// MARK: - Helpers

private func parse(_ source: String) throws -> TOMLTable {
    try TOMLParser.parse(source)
}

private func string(_ table: TOMLTable, _ key: String) -> String? {
    if case .string(let s) = table[key]?.value { return s }
    return nil
}

private func integer(_ table: TOMLTable, _ key: String) -> Int? {
    if case .integer(let i) = table[key]?.value { return i }
    return nil
}

private func double(_ table: TOMLTable, _ key: String) -> Double? {
    if case .double(let d) = table[key]?.value { return d }
    return nil
}

private func boolean(_ table: TOMLTable, _ key: String) -> Bool? {
    if case .boolean(let b) = table[key]?.value { return b }
    return nil
}

private func array(_ table: TOMLTable, _ key: String) -> [TOMLNode]? {
    if case .array(let a) = table[key]?.value { return a }
    return nil
}

private func subtable(_ table: TOMLTable, _ key: String) -> TOMLTable? {
    if case .table(let t) = table[key]?.value { return t }
    return nil
}

private func tableIn(_ node: TOMLNode) -> TOMLTable? {
    if case .table(let t) = node.value { return t }
    return nil
}

/// Parses expecting failure and returns the first diagnostic.
private func firstDiagnostic(_ t: TestContext, _ source: String) throws -> ConfigDiagnostic {
    let error = try t.expectThrows({ try TOMLParser.parse(source) }, "expected \(source) to fail parsing")
    let diagnostics = try t.require(error as? ConfigDiagnostics, "expected ConfigDiagnostics, got \(error)")
    return try t.require(diagnostics.items.first, "diagnostics were empty")
}

// MARK: - Suites

let tomlScalarTests = Suite("TOML scalars") { s in

    s.test("parses booleans") { t in
        let table = try parse("a = true\nb = false\n")
        t.expectEqual(boolean(table, "a"), true)
        t.expectEqual(boolean(table, "b"), false)
    }

    s.test("parses decimal integers with sign and underscores") { t in
        let table = try parse("a = 36\nb = -4\nc = +12\nd = 1_000_000\n")
        t.expectEqual(integer(table, "a"), 36)
        t.expectEqual(integer(table, "b"), -4)
        t.expectEqual(integer(table, "c"), 12)
        t.expectEqual(integer(table, "d"), 1_000_000)
    }

    s.test("treats 0 as a value, not as unset") { t in
        // Upstream SketchyBar cannot express margin=0 (issue #779). Ours must.
        t.expectEqual(integer(try parse("margin = 0\n"), "margin"), 0)
    }

    s.test("parses radix-prefixed integers") { t in
        let table = try parse("hex = 0xff\noct = 0o755\nbin = 0b1011\n")
        t.expectEqual(integer(table, "hex"), 255)
        t.expectEqual(integer(table, "oct"), 493)
        t.expectEqual(integer(table, "bin"), 11)
    }

    s.test("parses floats") { t in
        let table = try parse("a = 0.38\nb = -1.5\nc = 1e3\n")
        t.expectEqual(double(table, "a"), 0.38)
        t.expectEqual(double(table, "b"), -1.5)
        t.expectEqual(double(table, "c"), 1000)
    }

    s.test("keeps integers as integers") { t in
        let table = try parse("a = 12\n")
        t.expectEqual(integer(table, "a"), 12)
        t.expectNil(double(table, "a"), "an integer must not decay into a float")
    }
}

let tomlStringTests = Suite("TOML strings") { s in

    s.test("parses basic and literal strings") { t in
        let table = try parse("a = \"hello\"\nb = 'raw\\nnot-escaped'\n")
        t.expectEqual(string(table, "a"), "hello")
        t.expectEqual(string(table, "b"), "raw\\nnot-escaped")
    }

    s.test("decodes escape sequences") { t in
        let table = try parse("a = \"line\\nbreak\\ttab\\\"quote\\\\slash\"\n")
        t.expectEqual(string(table, "a"), "line\nbreak\ttab\"quote\\slash")
    }

    s.test("decodes unicode escapes") { t in
        let table = try parse("a = \"\\u00e9 \\U0001F600\"\n")
        t.expectEqual(string(table, "a"), "é 😀")
    }

    s.test("preserves nerd font glyphs verbatim") { t in
        // Private-use codepoints, the range nerd fonts live in.
        let table = try parse("icon = \"\u{f099e}\"\nalt = \"\u{f0999}\"\n")
        t.expectEqual(string(table, "icon"), "\u{f099e}")
        t.expectEqual(string(table, "alt"), "\u{f0999}")
    }

    s.test("parses multi-line strings and trims the leading newline") { t in
        t.expectEqual(string(try parse("a = \"\"\"\nfirst\nsecond\"\"\"\n"), "a"), "first\nsecond")
    }

    s.test("folds a line-continuation backslash") { t in
        t.expectEqual(string(try parse("a = \"\"\"one \\\n    two\"\"\"\n"), "a"), "one two")
    }

    s.test("multi-line literal strings do not process escapes") { t in
        t.expectEqual(string(try parse("a = '''raw\\nvalue'''\n"), "a"), "raw\\nvalue")
    }
}

let tomlCollectionTests = Suite("TOML collections") { s in

    s.test("parses arrays of integers") { t in
        let a = try t.require(array(try parse("ports = [3000, 3001, 5173]\n"), "ports"))
        t.expectEqual(a.map(\.value), [.integer(3000), .integer(3001), .integer(5173)])
    }

    s.test("arrays span lines and tolerate comments and a trailing comma") { t in
        let source = """
        watch = [
            "first",     # a comment
            "second",
        ]
        """
        let a = try t.require(array(try parse(source), "watch"))
        t.expectEqual(a.map(\.value), [.string("first"), .string("second")])
    }

    s.test("parses nested arrays") { t in
        let outer = try t.require(array(try parse("a = [[1, 2], [3]]\n"), "a"))
        t.expectEqual(outer.count, 2)
        guard case .array(let inner) = outer[0].value else {
            t.fail("expected a nested array")
            return
        }
        t.expectEqual(inner.map(\.value), [.integer(1), .integer(2)])
    }

    s.test("parses inline tables") { t in
        let font = try t.require(subtable(try parse("font = { family = \"JetBrainsMono\", size = 14 }\n"), "font"))
        t.expectEqual(string(font, "family"), "JetBrainsMono")
        t.expectEqual(integer(font, "size"), 14)
    }

    s.test("parses nested inline tables") { t in
        let a = try t.require(subtable(try parse("a = { b = { c = 1 } }\n"), "a"))
        t.expectEqual(integer(try t.require(subtable(a, "b")), "c"), 1)
    }

    s.test("parses an empty inline table") { t in
        t.expectEqual(subtable(try parse("a = {}\n"), "a")?.isEmpty, true)
    }
}

let tomlTableTests = Suite("TOML tables") { s in

    s.test("parses a standard table header") { t in
        t.expectEqual(integer(try t.require(subtable(try parse("[bar]\nheight = 36\n"), "bar")), "height"), 36)
    }

    s.test("parses nested table headers") { t in
        let theme = try t.require(subtable(try parse("[theme.pill]\ncorner_radius = 12\n"), "theme"))
        t.expectEqual(integer(try t.require(subtable(theme, "pill")), "corner_radius"), 12)
    }

    s.test("parses dotted keys") { t in
        let icon = try t.require(subtable(try parse("icon.font.size = 14\nicon.color = \"#f1d9a4\"\n"), "icon"))
        t.expectEqual(string(icon, "color"), "#f1d9a4")
        t.expectEqual(integer(try t.require(subtable(icon, "font")), "size"), 14)
    }

    s.test("parses an array of tables") { t in
        let source = """
        [[item]]
        id = "clock"

        [[item]]
        id = "battery"
        """
        let items = try t.require(array(try parse(source), "item"))
        t.expectEqual(items.count, 2)
        t.expectEqual(string(try t.require(tableIn(items[0])), "id"), "clock")
        t.expectEqual(string(try t.require(tableIn(items[1])), "id"), "battery")
    }

    s.test("a header under an array of tables targets the latest element") { t in
        let source = """
        [[group]]
        id = "workspaces_pill"

        [group.style]
        corner_radius = 12

        [[group]]
        id = "app_pill"
        """
        let groups = try t.require(array(try parse(source), "group"))
        t.expectEqual(groups.count, 2)
        let first = try t.require(tableIn(groups[0]))
        t.expectEqual(integer(try t.require(subtable(first, "style")), "corner_radius"), 12)
    }

    s.test("nested arrays of tables keep their parent association") { t in
        let source = """
        [[group]]
        id = "a"
        [[group.item]]
        id = "a1"
        [[group.item]]
        id = "a2"

        [[group]]
        id = "b"
        [[group.item]]
        id = "b1"
        """
        let groups = try t.require(array(try parse(source), "group"))
        t.expectEqual(groups.count, 2)
        t.expectEqual(array(try t.require(tableIn(groups[0])), "item")?.count, 2)
        t.expectEqual(array(try t.require(tableIn(groups[1])), "item")?.count, 1)
    }
}

let tomlOrderingTests = Suite("TOML ordering") { s in

    s.test("key order is preserved, because item order is render order") { t in
        t.expectEqual(try parse("z = 1\na = 2\nm = 3\n").keys, ["z", "a", "m"])
    }

    s.test("entries iterate in declaration order") { t in
        t.expectEqual(try parse("first = 1\nsecond = 2\nthird = 3\n").entries.map(\.key),
                      ["first", "second", "third"])
    }

    s.test("array-of-table order is preserved") { t in
        let source = """
        [[item]]
        id = "ports"
        [[item]]
        id = "status"
        [[item]]
        id = "battery"
        [[item]]
        id = "clock"
        """
        let ids = try t.require(array(try parse(source), "item")).compactMap { tableIn($0).flatMap { string($0, "id") } }
        t.expectEqual(ids, ["ports", "status", "battery", "clock"])
    }
}

let tomlTriviaTests = Suite("TOML trivia") { s in

    s.test("ignores comments and blank lines") { t in
        let source = """
        # leading comment

        a = 1   # trailing comment

        # another
        b = 2
        """
        let table = try parse(source)
        t.expectEqual(integer(table, "a"), 1)
        t.expectEqual(integer(table, "b"), 2)
    }

    s.test("handles CRLF line endings") { t in
        let table = try parse("a = 1\r\nb = 2\r\n")
        t.expectEqual(integer(table, "a"), 1)
        t.expectEqual(integer(table, "b"), 2)
    }

    s.test("handles a file with no trailing newline") { t in
        t.expectEqual(integer(try parse("a = 1"), "a"), 1)
    }

    s.test("handles an empty file") { t in
        t.expectEqual(try parse("").isEmpty, true)
        t.expectEqual(try parse("\n\n# just a comment\n").isEmpty, true)
    }
}

let tomlErrorTests = Suite("TOML errors") { s in

    s.test("rejects a missing equals sign at the right column") { t in
        let d = try firstDiagnostic(t, "[bar]\nheight 36\n")
        t.expectContains(d.message, "'='")
        t.expectEqual(d.location.line, 2)
        t.expectEqual(d.location.column, 8)
    }

    s.test("rejects a duplicate key") { t in
        let d = try firstDiagnostic(t, "a = 1\na = 2\n")
        t.expectContains(d.message, "more than once")
        t.expectEqual(d.location.line, 2)
    }

    s.test("rejects a duplicate table") { t in
        let d = try firstDiagnostic(t, "[bar]\na = 1\n[bar]\nb = 2\n")
        t.expectContains(d.message, "more than once")
        t.expectEqual(d.location.line, 3)
    }

    s.test("rejects an unterminated string") { t in
        t.expectContains(try firstDiagnostic(t, "a = \"oops\n").message, "unterminated")
    }

    s.test("rejects an unterminated array") { t in
        t.expectContains(try firstDiagnostic(t, "a = [1, 2\n").message, "unterminated")
    }

    s.test("rejects trailing junk after a value") { t in
        t.expectEqual(try firstDiagnostic(t, "a = 1 2\n").location.line, 1)
    }

    s.test("rejects datetimes explicitly rather than misparsing them") { t in
        let d = try firstDiagnostic(t, "a = 1979-05-27\n")
        t.expectContains(d.message, "date and time")
        t.expectContains(try t.require(d.hint), "quote it")
    }

    s.test("rejects an unrecognisable literal") { t in
        t.expectContains(try firstDiagnostic(t, "a = yes\n").message, "not a valid value")
    }

    s.test("rejects extending an inline table") { t in
        t.expectContains(try firstDiagnostic(t, "a = { b = 1 }\n[a.c]\nd = 2\n").message, "inline table")
    }

    s.test("rejects a value used as a table") { t in
        t.expectContains(try firstDiagnostic(t, "a = 1\n[a.b]\nc = 2\n").message, "value")
    }

    s.test("rejects mixing [table] and [[table]] for one key") { t in
        t.expectContains(try firstDiagnostic(t, "[a]\nx = 1\n[[a]]\ny = 2\n").message, "array of tables")
    }
}

let diagnosticRenderingTests = Suite("Diagnostic rendering") { s in

    s.test("renders a caret under the offending column") { t in
        let source = "[bar]\nheight 36\n"
        let d = ConfigDiagnostic(
            message: "expected '=' in key/value pair, found '3'",
            location: SourceLocation(line: 2, column: 8),
            hint: "keys and values are separated by '='"
        )

        let lines = d.render(path: "funkybar.toml", source: source).components(separatedBy: "\n")
        t.expectEqual(lines[0], "funkybar.toml:2:8: error: expected '=' in key/value pair, found '3'")
        t.expectEqual(lines[2], "2 | height 36")
        // "2 | " occupies 4 columns; 7 more spaces puts the caret under column 8.
        t.expectEqual(lines[3], "  |        ^")
        t.expectContains(lines[4], "hint: keys and values are separated by '='")
    }

    s.test("renders without source when none is available") { t in
        let d = ConfigDiagnostic(message: "boom", location: SourceLocation(line: 3, column: 1))
        t.expectEqual(d.render(path: nil, source: nil), "<config>:3:1: error: boom\n")
    }

    s.test("sorts collected diagnostics by position") { t in
        var diags = ConfigDiagnostics()
        diags.error("second", at: SourceLocation(line: 10, column: 1))
        diags.error("first", at: SourceLocation(line: 2, column: 5))
        diags.warn("middle", at: SourceLocation(line: 5, column: 1))

        t.expectEqual(diags.hasErrors, true)
        t.expectEqual(diags.errors.count, 2)
        t.expectEqual(diags.warnings.count, 1)

        let rendered = diags.render(path: "c.toml", source: nil)
        let firstAt = try t.require(rendered.range(of: "first"))
        let secondAt = try t.require(rendered.range(of: "second"))
        t.expect(firstAt.lowerBound < secondAt.lowerBound, "diagnostics should sort by line")
    }
}

let tomlSuites: [Suite] = [
    tomlRobustnessTests,
    tomlScalarTests,
    tomlStringTests,
    tomlCollectionTests,
    tomlTableTests,
    tomlOrderingTests,
    tomlTriviaTests,
    tomlErrorTests,
    diagnosticRenderingTests,
]

// MARK: - Robustness

// A malformed config must never take the daemon down. Each of these aborted
// the process before: three by stack overflow through unbounded recursion, one
// by a non-failable Int conversion trapping out of range.

let tomlRobustnessTests = Suite("TOML robustness") { s in

    s.test("deeply nested arrays are rejected, not fatal") { t in
        let source = "a = " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        t.expectContains(try firstDiagnostic(t, source).message, "nested more than")
    }

    s.test("deeply nested inline tables are rejected, not fatal") { t in
        let source = "a = " + String(repeating: "{b=", count: 6000) + "1" + String(repeating: "}", count: 6000)
        t.expectContains(try firstDiagnostic(t, source).message, "nested more than")
    }

    s.test("a very long dotted key is rejected, not fatal") { t in
        // A separate path from the two above: this one recursed in freeze().
        let source = (0 ..< 30_000).map { "k\($0)" }.joined(separator: ".") + " = 1"
        t.expectContains(try firstDiagnostic(t, source).message, "nested more than")
    }

    s.test("ordinary nesting still parses") { t in
        // The cap must not reject anything a real config would contain.
        let source = "a = " + String(repeating: "[", count: 32) + String(repeating: "]", count: 32)
        t.expectNoThrow { try TOMLParser.parse(source) }
        t.expectNoThrow { try TOMLParser.parse("a.b.c.d.e.f.g.h = 1") }
    }

    s.test("Int.min parses, which sign-stripping used to reject") { t in
        // The magnitude of Int.min does not fit a signed Int, so parsing the
        // digits signed after stripping "-" failed on a legal literal.
        let table = try parse("a = -9223372036854775808\nb = 9223372036854775807\n")
        t.expectEqual(integer(table, "a"), Int.min)
        t.expectEqual(integer(table, "b"), Int.max)
    }

    s.test("an out-of-range integer is an error, not a wrong number") { t in
        t.expectContains(try firstDiagnostic(t, "a = 99999999999999999999999\n").message,
                         "not a valid value")
    }

    s.test("a multi-line string is rejected as a key") { t in
        // parseQuotedString handles both forms, so `\"\"\"a\"\"\" = 1` silently
        // parsed as the key `a`. TOML forbids it.
        t.expectContains(try firstDiagnostic(t, "\"\"\"a\"\"\" = 1\n").message,
                         "multi-line string cannot be used as a key")
    }

    s.test("ordinary quoted keys still parse") { t in
        let table = try parse("\"a b\" = 1\n'c d' = 2\n")
        t.expectEqual(table.keys, ["a b", "c d"])
    }

    s.test("a float too large for Int is reported, not trapped") { t in
        // Int(Double) is non-failable and traps; `max_chars = 1e20` aborted.
        let outcome = ConfigDecoder.decode(try TOMLParser.parse("""
        [[item]]
        id = "x"
        [item.label]
        text = "hi"
        max_chars = 1e20
        """))
        t.expectContains(try t.require(outcome.diagnostics.errors.first).message, "too large")
    }
}
