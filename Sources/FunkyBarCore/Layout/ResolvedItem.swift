import CoreGraphics
import Foundation

/// An item with its templates rendered and its state applied.
///
/// This is the boundary between "what the config says" and "what to draw".
/// Providers produce field values; this type is the result of folding those
/// into the config. Layout consumes only this, never `ItemConfig`.
public struct ResolvedItem: Equatable, Sendable {
    public var id: String
    public var position: Position
    public var drawing: Bool

    public var icon: String
    public var label: String

    public var iconFont: FontSpec
    public var labelFont: FontSpec
    public var iconColor: Color
    public var labelColor: Color
    public var iconPadding: Insets
    public var labelPadding: Insets
    public var iconOffset: Offset
    public var labelOffset: Offset
    public var iconDrawing: Bool
    public var labelDrawing: Bool

    public var style: StyleSpec
    public var margin: Insets
    public var padding: Insets
    public var offset: Offset
    public var width: WidthSpec

    public init(id: String, position: Position = .left) {
        self.id = id
        self.position = position
        self.drawing = true
        self.icon = ""
        self.label = ""
        self.iconFont = .systemDefault
        self.labelFont = .systemDefault
        self.iconColor = .white
        self.labelColor = .white
        self.iconPadding = .zero
        self.labelPadding = .zero
        self.iconOffset = .zero
        self.labelOffset = .zero
        self.iconDrawing = true
        self.labelDrawing = true
        self.style = StyleSpec()
        self.margin = .zero
        self.padding = .zero
        self.offset = .zero
        self.width = .automatic
    }

    public var hasIcon: Bool { iconDrawing && !icon.isEmpty }
    public var hasLabel: Bool { labelDrawing && !label.isEmpty }
    /// An item with nothing to draw still occupies no space at all.
    public var isEmpty: Bool { !drawing || (!hasIcon && !hasLabel && !style.isVisible) }
}

/// Folds provider values and a named state into an `ItemConfig`.
public enum ItemResolver {

    /// - Parameters:
    ///   - values: provider fields, e.g. `["percent": "80", "state": "charging"]`
    ///   - stateName: which entry of `item.states` to apply; defaults to
    ///     `values["state"]`.
    public static func resolve(
        _ item: ItemConfig,
        values: [String: String] = [:],
        stateName: String? = nil
    ) -> ResolvedItem {
        var values = values
        // `{repeat}` addresses the loop value, so a repeated item can key an
        // image path or a provider channel off it.
        if let repeatValue = item.repeatValue {
            values["repeat"] = repeatValue
            if values["workspace"] == nil { values["workspace"] = repeatValue }
        }

        var out = ResolvedItem(id: item.id, position: item.position)
        out.drawing = item.drawing
        out.iconDrawing = item.icon.drawing
        out.labelDrawing = item.label.drawing
        out.icon = item.icon.template.render(values)
        out.label = item.label.template.render(values)
        out.iconFont = item.icon.font
        out.labelFont = item.label.font
        out.iconColor = item.icon.color
        out.labelColor = item.label.color
        out.iconPadding = item.icon.padding
        out.labelPadding = item.label.padding
        out.iconOffset = item.icon.offset
        out.labelOffset = item.label.offset
        out.style = item.style
        out.margin = item.margin
        out.padding = item.padding
        out.offset = item.offset
        out.width = item.width

        if let state = (stateName ?? values["state"]).flatMap({ item.states[$0] }) {
            if let icon = state.icon { out.icon = icon.render(values) }
            if let label = state.label { out.label = label.render(values) }
            // `color` sets both unless a more specific colour is also given.
            if let color = state.color {
                out.iconColor = color
                out.labelColor = color
            }
            if let color = state.iconColor { out.iconColor = color }
            if let color = state.labelColor { out.labelColor = color }
        }

        // Image paths may reference provider fields, so resolve them here
        // where the values are still in scope.
        if var image = out.style.image {
            let rendered = image.path.render(values)
            image.resolvedPath = (rendered as NSString).expandingTildeInPath
            out.style.image = image
        }

        out.icon = truncate(out.icon, to: item.icon.maxCharacters)
        out.label = truncate(out.label, to: item.label.maxCharacters)
        return out
    }

    /// Truncates on grapheme clusters, never bytes.
    ///
    /// Upstream issue #784: `max_chars` cuts CJK text mid-character because it
    /// counts bytes. `String.count` is cluster count, so this cannot.
    public static func truncate(_ text: String, to limit: Int?) -> String {
        guard let limit, limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
