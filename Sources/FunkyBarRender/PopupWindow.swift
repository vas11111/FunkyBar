import AppKit
import FunkyBarCore
import ImageIO

/// A popup hanging below one bar item.
///
/// Its own panel rather than a layer inside the bar, because it extends past
/// the bar's bounds and needs to receive clicks of its own. Rows come from the
/// provider; the config styles them.
///
/// Upstream builds popups by removing and re-adding sketchybar items on every
/// open, which is why the user's ports script regenerates its rows with a
/// shell loop and needs a separate `rebuild` path to avoid flashing. Here the
/// rows are data and the panel is reused.
@MainActor
final class PopupWindow {

    /// Row geometry, kept simple: a vertical stack sized to the widest row.
    private struct RowLayout {
        let row: PopupRow
        let frame: CGRect
        let icon: CGRect
        let label: CGRect
    }

    private let panel: BarPanel
    private let view: BarView
    private let root: CALayer
    private let shaper = CoreTextShaper()

    private var rows: [RowLayout] = []
    private var rowLayers: [String: (background: CALayer, icon: TextLayer, label: TextLayer)] = [:]
    private var backdrop: CALayer?

    private(set) var itemID: String
    private(set) var isVisible = false

    var onRowClick: ((String, PopupRow) -> Void)?
    /// Reports the mouse leaving the popup, for `mouse_exit` dismissal.
    var onMouseExit: (() -> Void)?

    init(itemID: String, config: BarConfig) {
        self.itemID = itemID

        panel = BarPanel(frame: CGRect(x: 0, y: 0, width: 10, height: 10), config: config)
        view = BarView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        panel.contentView = view
        root = view.layer!
        root.masksToBounds = false

        view.onMouseDown = { [weak self] point, _, _ in
            guard let self, let hit = self.rows.first(where: { $0.frame.contains(point) })
            else { return }
            guard hit.row.action != nil else { return }
            self.onRowClick?(self.itemID, hit.row)
        }
        view.onMouseMoved = { [weak self] point in
            guard point == nil else { return }
            self?.onMouseExit?()
        }
    }

    // MARK: - Content

    /// Lays the rows out and sizes the panel to fit.
    func apply(
        rows newRows: [PopupRow],
        spec: PopupSpec,
        defaults: DefaultsConfig,
        anchor: CGRect,
        screen: NSScreen,
        barConfig: BarConfig,
        contentsScale: CGFloat
    ) {
        let iconFont = defaults.icon.font
        let labelFont = defaults.label.font
        let iconPadding = defaults.icon.padding
        let labelPadding = defaults.label.padding
        let rowHeight = max(20, (iconFont.size + labelFont.size) / 2 + 10)
        let insets = spec.style.padding

        // Two columns: icons left-aligned, labels aligned to the widest icon,
        // so ports and process names line up instead of ragging.
        var iconWidths: [CGFloat] = []
        var labelWidths: [CGFloat] = []
        for row in newRows {
            iconWidths.append(shaper.shape(row.icon, font: iconFont)?.width ?? 0)
            labelWidths.append(shaper.shape(row.label, font: labelFont)?.width ?? 0)
        }
        let iconColumn = iconWidths.max() ?? 0
        let labelColumn = labelWidths.max() ?? 0

        // Columns line the labels up, which suits a port list; compact puts
        // each label straight after its icon, as sketchybar's rows do and at a
        // noticeably narrower popup.
        let useColumns = spec.rowAlignment == .columns
        let contentWidth: CGFloat
        if useColumns {
            contentWidth = iconPadding.horizontal + iconColumn
                + labelPadding.horizontal + labelColumn
        } else {
            contentWidth = zip(iconWidths, labelWidths)
                .map { iconPadding.horizontal + $0 + labelPadding.horizontal + $1 }
                .max() ?? 0
        }
        let width = contentWidth + insets.horizontal
        let height = CGFloat(newRows.count) * rowHeight + insets.vertical

        var laid: [RowLayout] = []
        for (index, row) in newRows.enumerated() {
            // Top-down visually; the view's origin is bottom-left.
            let top = height - insets.top - CGFloat(index + 1) * rowHeight
            let frame = CGRect(x: insets.leading, y: top, width: contentWidth, height: rowHeight)

            let iconWidth = iconWidths[index]
            let labelWidth = labelWidths[index]
            let iconX = frame.minX + iconPadding.leading
            let labelX = useColumns
                ? frame.minX + iconPadding.horizontal + iconColumn + labelPadding.leading
                : iconX + iconWidth + iconPadding.trailing + labelPadding.leading

            laid.append(RowLayout(
                row: row,
                frame: frame,
                icon: CGRect(x: iconX, y: frame.midY - iconFont.size / 2,
                             width: iconWidth, height: iconFont.size),
                label: CGRect(x: labelX, y: frame.midY - labelFont.size / 2,
                              width: labelWidth, height: labelFont.size)
            ))
        }
        rows = laid

        // Anchor under the item, clamped to the screen.
        var originX = anchor.minX
        let maxX = screen.frame.maxX - width - 4
        originX = min(max(screen.frame.minX + 4, originX), max(screen.frame.minX + 4, maxX))
        let originY = anchor.minY - height - 4

        panel.setFrame(
            CGRect(x: originX, y: originY, width: width, height: height),
            display: false
        )
        view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        panel.apply(barConfig)

        draw(spec: spec, defaults: defaults, size: CGSize(width: width, height: height),
             contentsScale: contentsScale)
    }

    private func draw(spec: PopupSpec, defaults: DefaultsConfig, size: CGSize, contentsScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        root.frame = CGRect(origin: .zero, size: size)

        let backdropLayer = backdrop ?? {
            let layer = CALayer()
            root.addSublayer(layer)
            backdrop = layer
            return layer
        }()
        backdropLayer.contentsScale = contentsScale
        backdropLayer.frame = CGRect(origin: .zero, size: size)
        backdropLayer.backgroundColor = spec.style.color.cgColor
        backdropLayer.borderColor = spec.style.borderColor.cgColor
        backdropLayer.borderWidth = CGFloat(spec.style.borderWidth)
        backdropLayer.cornerRadius = CGFloat(spec.style.corner.radius)

        var live = Set<String>()
        for layout in rows {
            live.insert(layout.row.id)
            let layers = rowLayers[layout.row.id] ?? {
                let background = CALayer()
                let icon = TextLayer()
                let label = TextLayer()
                for layer in [background, icon, label] as [CALayer] {
                    layer.contentsScale = contentsScale
                    root.addSublayer(layer)
                }
                rowLayers[layout.row.id] = (background, icon, label)
                return (background, icon, label)
            }()

            layers.background.frame = layout.frame
            layers.background.backgroundColor = NSColor.clear.cgColor

            let color = (layout.row.color ?? defaults.label.color).cgColor
            configure(layers.icon, text: layout.row.icon, font: defaults.icon.font,
                      color: color, rect: layout.icon)
            configure(layers.label, text: layout.row.label, font: defaults.label.font,
                      color: color, rect: layout.label)
        }

        for (id, layers) in rowLayers where !live.contains(id) {
            layers.background.removeFromSuperlayer()
            layers.icon.removeFromSuperlayer()
            layers.label.removeFromSuperlayer()
            rowLayers.removeValue(forKey: id)
        }

        CATransaction.commit()
    }

    private func configure(_ layer: TextLayer, text: String, font: FontSpec, color: CGColor, rect: CGRect) {
        guard let shaped = shaper.shape(text, font: font) else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        layer.shaped = shaped
        layer.color = color

        let pen = shaped.penPoint
        let baselineY = (rect.midY - (shaped.ascent - shaped.descent) / 2).rounded(.down)
        layer.frame = CGRect(
            x: rect.minX - pen.x,
            y: baselineY - pen.y,
            width: shaped.drawingSize.width,
            height: shaped.drawingSize.height
        )
        layer.penPoint = pen
    }

    // MARK: - Visibility

    func show() {
        guard !isVisible else { return }
        isVisible = true
        panel.orderFrontRegardless()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    func close() {
        hide()
        panel.close()
    }

    /// Renders the popup to a PNG, for the same reason the bar can: property
    /// comparison cannot see a drawing mistake.
    @discardableResult
    func capture(to path: String, scale: CGFloat = 2) -> Bool {
        let bounds = root.bounds
        let pixelWidth = Int((bounds.width * scale).rounded(.up))
        let pixelHeight = Int((bounds.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }

        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.32, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        root.render(in: context)

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// True when the point, in screen coordinates, is inside the popup.
    func contains(screenPoint: CGPoint) -> Bool {
        isVisible && panel.frame.contains(screenPoint)
    }
}
