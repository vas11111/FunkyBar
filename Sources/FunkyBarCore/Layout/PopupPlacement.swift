import CoreGraphics

/// Places a popup beside its anchor while keeping its viewport on screen.
public enum PopupPlacement {
    public static func frame(
        size: CGSize, anchor: CGRect, screen: CGRect,
        edge: BarEdge, alignment: Position = .left, gap: CGFloat = 4
    ) -> CGRect {
        let bounds = screen.insetBy(dx: gap, dy: gap)
        let width = min(max(1, size.width), max(1, bounds.width))
        let height = min(max(1, size.height), max(1, bounds.height))
        let x: CGFloat
        switch alignment {
        case .left: x = anchor.minX
        case .center: x = anchor.midX - width / 2
        case .right: x = anchor.maxX - width
        }
        let below = anchor.minY - gap - height
        let above = anchor.maxY + gap
        var y = edge == .top ? below : above
        if edge == .top, y < bounds.minY, above + height <= bounds.maxY { y = above }
        if edge == .bottom, y + height > bounds.maxY, below >= bounds.minY { y = below }
        return CGRect(x: min(max(x, bounds.minX), bounds.maxX - width),
                      y: min(max(y, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }
}
