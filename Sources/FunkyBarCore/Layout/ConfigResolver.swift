import Foundation

/// Folds live provider values into a `Config`, producing the tree the layout
/// engine consumes.
///
/// Dynamic `repeat` is expanded here rather than at config load, so a
/// workspace that appears or empties changes the bar without a reload.
/// Upstream issue #754 is exactly that staleness.
public enum ConfigResolver {

    public struct Inputs: Sendable {
        /// Provider fields per item id. Values for an expanded item fall back
        /// to its template's id.
        public var values: [String: [String: String]]
        /// Expansion sets for items whose `repeat` is provider-driven.
        public var repeats: [String: [String]]
        /// Explicit state override per item id, when not carried in `values`.
        public var states: [String: String]

        public init(
            values: [String: [String: String]] = [:],
            repeats: [String: [String]] = [:],
            states: [String: String] = [:]
        ) {
            self.values = values
            self.repeats = repeats
            self.states = states
        }
    }

    public static func resolve(_ config: Config, inputs: Inputs = Inputs()) -> [ResolvedNode] {
        config.nodes.map { node in
            switch node {
            case .item(let item):
                let expanded = expand(item, inputs: inputs)
                // A bare item that expands to several becomes an implicit
                // group, so the pieces stay adjacent and share spacing.
                if expanded.count == 1 {
                    return .item(expanded[0])
                }
                return .group(
                    ResolvedGroup(
                        id: item.id,
                        position: item.position,
                        style: StyleSpec(),
                        margin: .zero,
                        items: expanded
                    )
                )

            case .group(let group):
                var resolved = ResolvedGroup(
                    id: group.id,
                    position: group.position,
                    style: group.style,
                    margin: group.margin,
                    padding: group.padding,
                    spacing: group.spacing,
                    drawing: group.drawing
                )
                resolved.items = group.items.flatMap { expand($0, inputs: inputs) }
                return .group(resolved)
            }
        }
    }

    /// One config item becomes one or more resolved items.
    private static func expand(_ item: ItemConfig, inputs: Inputs) -> [ResolvedItem] {
        guard case .dynamic(let field)? = item.repeatSource else {
            return [ItemResolver.resolve(item, values: values(for: item, inputs: inputs),
                                         stateName: inputs.states[item.id])]
        }

        // Provider-driven expansion. With nothing reported yet, the template
        // contributes no items rather than rendering a placeholder.
        let expansion = inputs.repeats[item.id] ?? []
        return expansion.map { value in
            var clone = item
            clone.id = "\(item.id).\(value)"
            clone.repeatValue = value

            var fields = values(for: clone, inputs: inputs)
            if fields[field] == nil { fields[field] = value }

            return ItemResolver.resolve(
                clone,
                values: fields,
                stateName: inputs.states[clone.id] ?? fields["state"]
            )
        }
    }

    /// Values addressed to the exact id win; otherwise fall back to the
    /// template id, so one provider can feed every clone.
    public static func values(for item: ItemConfig, inputs: Inputs) -> [String: String] {
        var base: [String: String] = [:]
        if let repeatValue = item.repeatValue {
            let templateID = String(item.id.dropLast(repeatValue.count + 1))
            base = inputs.values[templateID] ?? [:]
        }
        base.merge(inputs.values[item.id] ?? [:]) { _, new in new }
        if let repeatValue = item.repeatValue {
            base["repeat"] = repeatValue
            if base["workspace"] == nil { base["workspace"] = repeatValue }
            if case .dynamic(let field) = item.repeatSource, base[field] == nil {
                base[field] = repeatValue
            }
        }
        return base
    }
}
