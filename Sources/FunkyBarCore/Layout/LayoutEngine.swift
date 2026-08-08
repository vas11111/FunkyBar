import CoreGraphics
import Foundation

// MARK: - Input tree

public struct ResolvedGroup: Equatable, Sendable {
    public var id: String
    public var position: Position
    public var style: StyleSpec
    public var margin: Insets
    public var padding: Insets
    public var spacing: Double
    public var drawing: Bool
    public var items: [ResolvedItem]

    public init(
        id: String,
        position: Position = .left,
        style: StyleSpec = StyleSpec(),
        margin: Insets = .zero,
        padding: Insets = .zero,
        spacing: Double = 0,
        drawing: Bool = true,
        items: [ResolvedItem] = []
    ) {
        self.id = id
        self.position = position
        self.style = style
        self.margin = margin
        self.padding = padding
        self.spacing = spacing
        self.drawing = drawing
        self.items = items
    }

    public var visibleItems: [ResolvedItem] { items.filter { !$0.isEmpty } }
}

public enum ResolvedNode: Equatable, Sendable {
    case item(ResolvedItem)
    case group(ResolvedGroup)

    public var id: String {
        switch self {
        case .item(let item):   item.id
        case .group(let group): group.id
        }
    }

    public var position: Position {
        switch self {
        case .item(let item):   item.position
        case .group(let group): group.position
        }
    }

    var isEmpty: Bool {
        switch self {
        case .item(let item):   item.isEmpty
        case .group(let group): !group.drawing || group.visibleItems.isEmpty
        }
    }
}

// MARK: - Output

public struct ItemFrame: Equatable, Sendable {
    public var id: String
    /// Content box, excluding margin.
    public var frame: CGRect
    /// The drawn background box, which may be taller than the content.
    public var background: CGRect
    public var icon: CGRect
    public var label: CGRect
}

public struct GroupFrame: Equatable, Sendable {
    public var id: String
    public var frame: CGRect
    public var background: CGRect
    public var itemIDs: [String]
}

public struct BarLayout: Equatable, Sendable {
    public var bounds: CGRect
    public var items: [ItemFrame]
    public var groups: [GroupFrame]

    public func item(_ id: String) -> ItemFrame? { items.first { $0.id == id } }

    /// The id of the topmost item under `point`, in bar coordinates.
    ///
    /// A pure function of the layout so it can be tested without a window.
    /// Later siblings win where boxes overlap, matching draw order.
    public func hitTest(_ point: CGPoint) -> String? {
        for frame in items.reversed() {
            let box = frame.background == .zero
                ? frame.frame
                : frame.background.union(frame.frame)
            if box.contains(point) { return frame.id }
        }
        return nil
    }
    public func group(_ id: String) -> GroupFrame? { groups.first { $0.id == id } }

    /// Total width occupied on one side, useful for overflow checks.
    public func contentWidth(at position: Position, in config: Config) -> Double {
        items.filter { frame in
            config.allItems.first { $0.id == frame.id }?.position == position
        }
        .reduce(0) { $0 + $1.frame.width }
    }
}

// MARK: - Engine

/// Single measure-then-arrange pass over an immutable tree.
///
/// No mutation happens during layout, so the whole engine is testable without
/// a display. Two structural differences from upstream:
///
/// - A group is a real container that sizes to its children plus its own
///   insets, so `style.height` is optional (#639) and a group's margin does
///   not swallow its children's.
/// - Declaration order is visual order on both sides. Upstream inserts `right`
///   items rightmost-first, which is why a sketchybarrc has to declare the
///   right side backwards.
public enum LayoutEngine {

    public static func layout(
        nodes: [ResolvedNode],
        bar: BarConfig,
        width: Double,
        measuring: any TextMeasuring
    ) -> BarLayout {
        let bounds = CGRect(x: 0, y: 0, width: width, height: bar.height)
        var items: [ItemFrame] = []
        var groups: [GroupFrame] = []

        let drawable = nodes.filter { !$0.isEmpty }

        for position in [Position.left, .center, .right] {
            let side = drawable.filter { $0.position == position }
            guard !side.isEmpty else { continue }

            let measured = side.map { measure($0, measuring: measuring) }
            let total = measured.reduce(0) { $0 + $1.outerWidth }

            var cursor: Double
            switch position {
            case .left:
                cursor = bar.padding.leading
            case .right:
                cursor = width - bar.padding.trailing - total
            case .center:
                cursor = (width - total) / 2
            }

            for (node, size) in zip(side, measured) {
                cursor += size.margin.leading
                place(
                    node,
                    measured: size,
                    originX: cursor,
                    bar: bar,
                    measuring: measuring,
                    items: &items,
                    groups: &groups
                )
                cursor += size.width + size.margin.trailing
            }
        }

        return BarLayout(bounds: bounds, items: items, groups: groups)
    }

    // MARK: - Measurement

    struct Measured {
        var width: Double
        var height: Double
        var margin: Insets
        /// Per-child measurements, for groups.
        var children: [Measured]

        var outerWidth: Double { width + margin.horizontal }
    }

    static func measure(_ node: ResolvedNode, measuring: any TextMeasuring) -> Measured {
        switch node {
        case .item(let item):
            return measure(item, measuring: measuring)
        case .group(let group):
            let children = group.visibleItems.map { measure($0, measuring: measuring) }

            // A group's box includes its children's outer margins. Measured
            // from sketchybar's own item windows: the workspaces bracket sits
            // at x=10 w=195 with its first child at x=13 and the last ending at
            // 202, so the bracket extends 3pt past the children on each side.
            // An earlier version excluded those, on a misreading of the comment
            // in the sketchybarrc about brackets swallowing member margins.
            let spacing = group.spacing * Double(max(0, children.count - 1))
            let childrenWidth = children.reduce(0) { $0 + $1.outerWidth } + spacing

            let childrenHeight = children.map(\.height).max() ?? 0
            return Measured(
                width: childrenWidth + group.padding.horizontal,
                height: childrenHeight + group.padding.vertical,
                margin: group.margin,
                children: children
            )
        }
    }

    static func measure(_ item: ResolvedItem, measuring: any TextMeasuring) -> Measured {
        let iconSize = item.hasIcon ? measuring.size(of: item.icon, font: item.iconFont) : .zero
        let labelSize = item.hasLabel ? measuring.size(of: item.label, font: item.labelFont) : .zero

        let iconBox = item.hasIcon ? iconSize.width + item.iconPadding.horizontal : 0
        let labelBox = item.hasLabel ? labelSize.width + item.labelPadding.horizontal : 0

        let contentWidth = iconBox + labelBox
        let contentHeight = max(iconSize.height, labelSize.height)

        let automatic = contentWidth + item.padding.horizontal
        let width: Double
        switch item.width {
        case .automatic:      width = automatic
        case .fixed(let value): width = value
        }

        return Measured(
            width: width,
            height: contentHeight + item.padding.vertical,
            margin: item.margin,
            children: []
        )
    }

    // MARK: - Placement

    private static func place(
        _ node: ResolvedNode,
        measured: Measured,
        originX: Double,
        bar: BarConfig,
        measuring: any TextMeasuring,
        items: inout [ItemFrame],
        groups: inout [GroupFrame]
    ) {
        switch node {
        case .item(let item):
            items.append(placeItem(item, measured: measured, originX: originX, bar: bar, measuring: measuring))

        case .group(let group):
            let centerY = bar.height / 2 + bar.offset.y
            let frame = CGRect(
                x: originX,
                y: centerY - measured.height / 2,
                width: measured.width,
                height: measured.height
            )

            var cursor = originX + group.padding.leading
            var childIDs: [String] = []

            for (child, childSize) in zip(group.visibleItems, measured.children) {
                cursor += childSize.margin.leading
                items.append(
                    placeItem(child, measured: childSize, originX: cursor, bar: bar, measuring: measuring)
                )
                childIDs.append(child.id)
                cursor += childSize.width + childSize.margin.trailing + group.spacing
            }

            groups.append(
                GroupFrame(
                    id: group.id,
                    frame: frame,
                    background: backgroundRect(for: frame, style: group.style, bar: bar),
                    itemIDs: childIDs
                )
            )
        }
    }

    private static func placeItem(
        _ item: ResolvedItem,
        measured: Measured,
        originX: Double,
        bar: BarConfig,
        measuring: any TextMeasuring
    ) -> ItemFrame {
        let centerY = bar.height / 2 + bar.offset.y + item.offset.y
        let frame = CGRect(
            x: originX + item.offset.x,
            y: centerY - measured.height / 2,
            width: measured.width,
            height: measured.height
        )

        var cursor = frame.minX + item.padding.leading
        var iconRect = CGRect.zero
        var labelRect = CGRect.zero

        if item.hasIcon {
            let size = measuring.size(of: item.icon, font: item.iconFont)
            iconRect = CGRect(
                x: cursor + item.iconPadding.leading + item.iconOffset.x,
                y: frame.midY - size.height / 2 + item.iconOffset.y,
                width: size.width,
                height: size.height
            )
            cursor += size.width + item.iconPadding.horizontal
        }

        if item.hasLabel {
            let size = measuring.size(of: item.label, font: item.labelFont)
            labelRect = CGRect(
                x: cursor + item.labelPadding.leading + item.labelOffset.x,
                y: frame.midY - size.height / 2 + item.labelOffset.y,
                width: size.width,
                height: size.height
            )
        }

        return ItemFrame(
            id: item.id,
            frame: frame,
            background: backgroundRect(for: frame, style: item.style, bar: bar),
            icon: iconRect,
            label: labelRect
        )
    }

    /// The drawn box behind a node.
    ///
    /// `style.height == nil` means size-to-content. Upstream makes that state
    /// disappear entirely (#639); here it is the sensible default.
    private static func backgroundRect(for frame: CGRect, style: StyleSpec, bar: BarConfig) -> CGRect {
        guard style.isVisible else { return .zero }

        let width = frame.width + style.padding.horizontal
        let height = style.height ?? (frame.height + style.padding.vertical)

        return CGRect(
            x: frame.minX - style.padding.leading,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
