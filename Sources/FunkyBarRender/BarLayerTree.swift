import AppKit
import FunkyBarCore

/// Owns the CALayer tree for one bar and applies layouts to it.
///
/// The whole tree lives in a single window. Upstream creates one SkyLight
/// window per item, which is what lets the compositor observe a half-updated
/// bar; here every change lands inside one `CATransaction`, so a partial frame
/// is never presented (#726, #834, #808).
///
/// Updates are diffed: a property is only assigned when its value actually
/// changed, so an unchanged clock string costs a handful of comparisons and no
/// redraw at all.
@MainActor
final class BarLayerTree {

    private struct ItemLayers {
        var background: CALayer?
        var icon: TextLayer?
        var label: TextLayer?

        // Last applied values, for diffing.
        var iconText: String = ""
        var labelText: String = ""
        var iconFont: FontSpec = .systemDefault
        var labelFont: FontSpec = .systemDefault
    }

    let root: CALayer
    private let groupBackgrounds = CALayer()
    private let itemBackgrounds = CALayer()
    private let textLayer = CALayer()

    private var items: [String: ItemLayers] = [:]
    private var groups: [String: CALayer] = [:]
    private var imageCache: [String: CGImage] = [:]

    private let shaper = CoreTextShaper()
    private var scale: CGFloat = 2

    init(root: CALayer) {
        self.root = root
        // Three flat containers rather than nesting: group backgrounds must sit
        // under every item, and z-order is then a property of the container
        // rather than of insertion order.
        for container in [groupBackgrounds, itemBackgrounds, textLayer] {
            container.frame = root.bounds
            container.masksToBounds = false
            container.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull()]
            root.addSublayer(container)
        }
    }

    func setContentsScale(_ newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        applyScale(to: root)
    }

    private func applyScale(to layer: CALayer) {
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] { applyScale(to: sublayer) }
    }

    // MARK: - Apply

    func apply(layout: BarLayout, nodes: [ResolvedNode]) {
        CATransaction.begin()
        // Implicit animations on a status bar read as lag, not polish.
        CATransaction.setDisableActions(true)

        for container in [groupBackgrounds, itemBackgrounds, textLayer] {
            container.frame = layout.bounds
        }

        var liveItems = Set<String>()
        var liveGroups = Set<String>()

        let resolvedItems = flatten(nodes)

        for frame in layout.groups {
            liveGroups.insert(frame.id)
            let style = groupStyle(for: frame.id, in: nodes)
            applyGroup(frame, style: style)
        }

        for frame in layout.items {
            guard let item = resolvedItems[frame.id] else { continue }
            liveItems.insert(frame.id)
            applyItem(frame, item: item)
        }

        // Remove what the new layout no longer contains.
        for (id, layers) in items where !liveItems.contains(id) {
            layers.background?.removeFromSuperlayer()
            layers.icon?.removeFromSuperlayer()
            layers.label?.removeFromSuperlayer()
            items.removeValue(forKey: id)
        }
        for (id, layer) in groups where !liveGroups.contains(id) {
            layer.removeFromSuperlayer()
            groups.removeValue(forKey: id)
        }

        CATransaction.commit()
    }

    private func flatten(_ nodes: [ResolvedNode]) -> [String: ResolvedItem] {
        var out: [String: ResolvedItem] = [:]
        for node in nodes {
            switch node {
            case .item(let item):
                out[item.id] = item
            case .group(let group):
                for item in group.items { out[item.id] = item }
            }
        }
        return out
    }

    private func groupStyle(for id: String, in nodes: [ResolvedNode]) -> StyleSpec {
        for case .group(let group) in nodes where group.id == id { return group.style }
        return StyleSpec()
    }

    // MARK: - Groups

    private func applyGroup(_ frame: GroupFrame, style: StyleSpec) {
        guard style.isVisible, frame.background != .zero else {
            groups[frame.id]?.removeFromSuperlayer()
            groups.removeValue(forKey: frame.id)
            return
        }

        let layer = groups[frame.id] ?? makeBackgroundLayer(in: groupBackgrounds)
        groups[frame.id] = layer
        configure(layer, frame: frame.background, style: style)
    }

    // MARK: - Items

    private func applyItem(_ frame: ItemFrame, item: ResolvedItem) {
        var layers = items[frame.id] ?? ItemLayers()

        // Background
        if item.style.isVisible, frame.background != .zero {
            let layer = layers.background ?? makeBackgroundLayer(in: itemBackgrounds)
            layers.background = layer
            configure(layer, frame: frame.background, style: item.style)
        } else {
            layers.background?.removeFromSuperlayer()
            layers.background = nil
        }

        // Icon
        if item.hasIcon {
            let layer = layers.icon ?? makeTextLayer()
            layers.icon = layer
            if layers.iconText != item.icon || layers.iconFont != item.iconFont {
                layer.shaped = shaper.shape(item.icon, font: item.iconFont)
                layers.iconText = item.icon
                layers.iconFont = item.iconFont
            }
            let cgColor = item.iconColor.cgColor
            if layer.color != cgColor { layer.color = cgColor }
            if layer.frame != frame.icon { layer.frame = frame.icon }
        } else {
            layers.icon?.removeFromSuperlayer()
            layers.icon = nil
            layers.iconText = ""
        }

        // Label
        if item.hasLabel {
            let layer = layers.label ?? makeTextLayer()
            layers.label = layer
            if layers.labelText != item.label || layers.labelFont != item.labelFont {
                layer.shaped = shaper.shape(item.label, font: item.labelFont)
                layers.labelText = item.label
                layers.labelFont = item.labelFont
            }
            let cgColor = item.labelColor.cgColor
            if layer.color != cgColor { layer.color = cgColor }
            if layer.frame != frame.label { layer.frame = frame.label }
        } else {
            layers.label?.removeFromSuperlayer()
            layers.label = nil
            layers.labelText = ""
        }

        items[frame.id] = layers
    }

    // MARK: - Layer construction

    private func makeBackgroundLayer(in container: CALayer) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = scale
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(),
            "borderColor": NSNull(), "borderWidth": NSNull(), "cornerRadius": NSNull(),
            "contents": NSNull(), "hidden": NSNull(),
        ]
        container.addSublayer(layer)
        return layer
    }

    private func makeTextLayer() -> TextLayer {
        let layer = TextLayer()
        layer.contentsScale = scale
        textLayer.addSublayer(layer)
        return layer
    }

    private func configure(_ layer: CALayer, frame: CGRect, style: StyleSpec) {
        if layer.frame != frame { layer.frame = frame }

        let background = style.color.cgColor
        if layer.backgroundColor != background { layer.backgroundColor = background }

        let radius = CGFloat(style.corner.radius)
        if layer.cornerRadius != radius {
            layer.cornerRadius = radius
            // Continuous curvature matches the rest of macOS; the difference is
            // visible at the 12pt radius this config uses.
            layer.cornerCurve = style.corner.style == .squircle ? .continuous : .circular
        }

        let borderWidth = CGFloat(style.borderWidth)
        if layer.borderWidth != borderWidth { layer.borderWidth = borderWidth }
        let borderColor = style.borderColor.cgColor
        if layer.borderColor != borderColor { layer.borderColor = borderColor }

        if let image = style.image {
            layer.contents = loadImage(image.path)
            layer.contentsGravity = .resizeAspect
            layer.masksToBounds = true
        } else if layer.contents != nil {
            layer.contents = nil
        }

        if let shadow = style.shadow {
            layer.shadowColor = shadow.color.cgColor
            layer.shadowRadius = CGFloat(shadow.radius)
            layer.shadowOpacity = Float(shadow.opacity)
            layer.shadowOffset = CGSize(width: shadow.offset.x, height: shadow.offset.y)
        } else if layer.shadowOpacity != 0 {
            layer.shadowOpacity = 0
        }
    }

    private func loadImage(_ path: String) -> CGImage? {
        if let cached = imageCache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        imageCache[path] = cgImage
        return cgImage
    }

    func invalidateImageCache() {
        imageCache.removeAll()
    }
}
