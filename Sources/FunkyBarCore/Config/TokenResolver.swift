import Foundation

/// Substitutes theme tokens before decoding.
///
/// A value that is *exactly* `$name` or `$a.b` is replaced by whatever the
/// theme defines under that path, which may be a scalar or a whole table. The
/// exact-match rule is what keeps `"${price}"` unambiguous: it contains braces,
/// so it is a render-time template, not a token reference.
///
/// A leading `theme.` is optional, so `$theme.pill` and `$pill` are the same
/// token.
public enum TokenResolver {
    private static let maxDepth = 16
    private struct Budget {
        var remaining = 20_000
        var reported = false
    }

    public static func resolve(
        _ root: TOMLTable,
        diagnostics: inout ConfigDiagnostics
    ) -> TOMLTable {
        guard case .table(let theme)? = root["theme"]?.value else {
            // No theme table: any surviving $ref is an error, reported below.
            return substitute(in: root, theme: TOMLTable(), diagnostics: &diagnostics)
        }

        // Tokens may reference other tokens; settle the theme first.
        var settled = theme
        for _ in 0 ..< maxDepth {
            var pass = ConfigDiagnostics()
            let next = substitute(in: settled, theme: settled, diagnostics: &pass)
            if pass.hasErrors {
                diagnostics.merge(pass)
                return root
            }
            if next == settled { break }
            settled = next
        }

        // Settling converges a cycle to a self-reference (a -> b -> a becomes
        // a = "$a") rather than diverging, so comparing passes cannot detect
        // it. Instead look for any surviving reference that still resolves:
        // an unresolved-but-resolvable token is by definition circular.
        reportCycles(in: settled, theme: settled, path: [], diagnostics: &diagnostics)

        return substitute(in: root, theme: settled, diagnostics: &diagnostics)
    }

    private static func reportCycles(
        in table: TOMLTable,
        theme: TOMLTable,
        path: [String],
        diagnostics: inout ConfigDiagnostics
    ) {
        for (key, node) in table.entries {
            switch node.value {
            case .string(let text):
                guard let target = tokenPath(text), lookup(target, in: theme) != nil else { continue }
                let name = (path + [key]).joined(separator: ".")
                diagnostics.error(
                    "theme token '$\(name)' is part of a reference cycle",
                    at: node.location,
                    hint: "a token cannot depend on itself, directly or indirectly"
                )
            case .table(let child):
                reportCycles(in: child, theme: theme, path: path + [key], diagnostics: &diagnostics)
            default:
                continue
            }
        }
    }

    // MARK: - Substitution

    private static func substitute(
        in table: TOMLTable,
        theme: TOMLTable,
        diagnostics: inout ConfigDiagnostics
    ) -> TOMLTable {
        var budget = Budget()
        return substitute(in: table, theme: theme, diagnostics: &diagnostics,
                          depth: 0, budget: &budget)
    }

    private static func substitute(
        in table: TOMLTable,
        theme: TOMLTable,
        diagnostics: inout ConfigDiagnostics,
        depth: Int,
        budget: inout Budget
    ) -> TOMLTable {
        var out = TOMLTable(location: table.location)
        for (key, node) in table.entries {
            let resolved = substitute(node: node, theme: theme, diagnostics: &diagnostics,
                                      depth: depth + 1, budget: &budget)
            out.insert(resolved, for: key)
            if budget.remaining <= 0 { break }
        }
        return out
    }

    private static func substitute(
        node: TOMLNode,
        theme: TOMLTable,
        diagnostics: inout ConfigDiagnostics,
        depth: Int,
        budget: inout Budget
    ) -> TOMLNode {
        guard depth <= 64, budget.remaining > 0 else {
            if !budget.reported {
                diagnostics.error("theme expansion exceeds the nesting or size limit", at: node.location,
                                  hint: "remove recursive table/array tokens or reduce the expanded theme")
                budget.reported = true
            }
            return TOMLNode(.string(""), at: node.location)
        }
        budget.remaining -= 1
        if budget.remaining == 0, !budget.reported {
            diagnostics.error("theme expansion exceeds the size limit", at: node.location,
                              hint: "remove recursive table/array tokens or reduce the expanded theme")
            budget.reported = true
        }
        switch node.value {
        case .string(let text):
            guard let path = tokenPath(text) else { return node }
            guard let resolved = lookup(path, in: theme) else {
                diagnostics.error(
                    "unknown theme token '\(text)'",
                    at: node.location,
                    hint: available(in: theme)
                )
                return node
            }
            // Keep the *use site* location so errors point at the use, not the
            // definition.
            return TOMLNode(resolved.value, at: node.location)

        case .array(let elements):
            var resolved: [TOMLNode] = []
            for element in elements {
                resolved.append(substitute(node: element, theme: theme, diagnostics: &diagnostics,
                                           depth: depth + 1, budget: &budget))
                if budget.remaining <= 0 { break }
            }
            return TOMLNode(.array(resolved), at: node.location)

        case .table(let child):
            return TOMLNode(
                .table(substitute(in: child, theme: theme, diagnostics: &diagnostics,
                                  depth: depth, budget: &budget)),
                at: node.location
            )

        case .integer, .double, .boolean:
            return node
        }
    }

    /// Returns the token path for an exact `$ref`, or nil for anything else.
    private static func tokenPath(_ text: String) -> [String]? {
        guard text.hasPrefix("$"), text.count > 1 else { return nil }
        let body = String(text.dropFirst())

        // Reject anything that is not purely a dotted identifier, so templates
        // like "${price}" and literals like "$5" fall through untouched.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        guard body.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let first = body.first, first.isLetter || first == "_" else { return nil }
        guard !body.hasSuffix("."), !body.contains("..") else { return nil }

        var parts = body.split(separator: ".").map(String.init)
        if parts.first == "theme" { parts.removeFirst() }
        return parts.isEmpty ? nil : parts
    }

    private static func lookup(_ path: [String], in theme: TOMLTable) -> TOMLNode? {
        var current: TOMLNode? = nil
        var table = theme

        for (index, key) in path.enumerated() {
            guard let node = table[key] else { return nil }
            current = node
            if index < path.count - 1 {
                guard case .table(let child) = node.value else { return nil }
                table = child
            }
        }
        return current
    }

    private static func available(in theme: TOMLTable) -> String? {
        guard !theme.isEmpty else { return "no [theme] table is defined" }
        let names = theme.keys.sorted().prefix(12).map { "$\($0)" }.joined(separator: ", ")
        return "available tokens: \(names)\(theme.count > 12 ? ", ..." : "")"
    }
}
