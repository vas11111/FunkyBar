import AppKit
import FunkyBarCore
import ImageIO
import UniformTypeIdentifiers

/// What the bar reports back to the daemon.
public struct BarEvent: Sendable {
    public enum Kind: Sendable {
        case click(MouseButton)
        case scroll(delta: Double, precise: Bool)
        case hoverEnter
        case hoverExit
    }

    public let itemID: String
    public let kind: Kind
    /// Which display the event happened on. Without this a popup anchors to
    /// whichever display a dictionary happens to yield first, which is upstream
    /// issue #742: the popup opens on the wrong screen.
    public let displayID: CGDirectDisplayID

    public init(itemID: String, kind: Kind, displayID: CGDirectDisplayID = 0) {
        self.itemID = itemID
        self.kind = kind
        self.displayID = displayID
    }
}

/// One display's bar.
@MainActor
final class BarDisplay {
    let panel: BarPanel
    let view: BarView
    let tree: BarLayerTree
    private(set) var screen: NSScreen
    private(set) var lastLayout: BarLayout?

    init(screen: NSScreen, config: BarConfig) {
        self.screen = screen
        let frame = BarDisplay.frame(for: screen, config: config)

        panel = BarPanel(frame: frame, config: config)
        view = BarView(frame: CGRect(origin: .zero, size: frame.size))
        panel.contentView = view

        tree = BarLayerTree(root: view.layer!)
        tree.setContentsScale(BarDisplay.renderScale(for: screen))
    }

    /// sketchybar calls SLSSetWindowResolution(window, 2.0) on every window
    /// regardless of the display it lands on, so its text is supersampled on a
    /// non-retina monitor. Following backingScaleFactor instead renders at 1x
    /// there, which reads as thinner and smaller beside it.
    static func renderScale(for screen: NSScreen) -> CGFloat {
        max(2, screen.backingScaleFactor)
    }

    static func frame(for screen: NSScreen, config: BarConfig) -> CGRect {
        let visible = screen.frame
        let width = visible.width - config.margin.horizontal
        let x = visible.minX + config.margin.leading + config.offset.x

        // The offset moves the bar, not its contents. sketchybar's windows sit
        // at screen y=4 with y_offset=4, so a positive offset pushes a top bar
        // down from the screen edge. Applying it to the contents instead left
        // every pill 8pt high: 4pt from moving them the wrong way, 4pt from not
        // moving the bar.
        let y: CGFloat
        switch config.edge {
        case .top:
            y = visible.maxY - config.height - config.margin.top - config.offset.y
        case .bottom:
            y = visible.minY + config.margin.bottom + config.offset.y
        }

        return CGRect(x: x, y: y, width: width, height: config.height)
    }

    func reposition(config: BarConfig) {
        let frame = BarDisplay.frame(for: screen, config: config)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = CGRect(origin: .zero, size: frame.size)
        }
        panel.apply(config)
        tree.setContentsScale(BarDisplay.renderScale(for: screen))
    }

    func update(screen: NSScreen) {
        self.screen = screen
    }

    func apply(nodes: [ResolvedNode], config: BarConfig, measuring: any TextMeasuring) {
        tree.allowsFontSmoothing = config.fontSmoothing
        let result = LayoutEngine.layout(
            nodes: nodes,
            bar: config,
            width: panel.frame.width,
            measuring: measuring
        )
        lastLayout = result
        tree.apply(layout: result, nodes: nodes)
    }

    /// The topmost item under a point, or nil.
    func hitTest(_ point: CGPoint) -> String? {
        lastLayout?.hitTest(point)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

/// Owns one bar per display and keeps them in step with the config.
@MainActor
public final class BarController {

    public var onEvent: ((BarEvent) -> Void)?

    private var displays: [CGDirectDisplayID: BarDisplay] = [:]
    private var config: BarConfig
    private var nodes: [ResolvedNode] = []
    private let measuring: CachingTextMeasurer
    private var hovered: String?
    private var popups: [String: PopupWindow] = [:]
    private var popupRows: [String: [PopupRow]] = [:]
    private var outsideClickMonitor: Any?
    private var popupTimeout: DispatchWorkItem?

    /// Fired when a popup row with an action is clicked.
    public var onPopupAction: ((String, String) -> Void)?
    /// Suspended while the screens are asleep, so nothing lays out or draws.
    private(set) var isSuspended = false

    public init(config: BarConfig = BarConfig()) {
        self.config = config
        self.measuring = CachingTextMeasurer(CoreTextMeasurer())
        observeScreenChanges()
    }

    // MARK: - Config

    public func apply(config newConfig: BarConfig) {
        config = newConfig
        // A reload may have changed fonts or sizes, and rebuilding the
        // measurement cache costs far less than shipping stale metrics.
        measuring.invalidate()
        syncDisplays()
        for display in displays.values { display.reposition(config: config) }
        redraw()
    }

    public func apply(nodes newNodes: [ResolvedNode]) {
        nodes = newNodes
        redraw()
        // A visible popup must follow its provider, not freeze at whatever was
        // true when it opened.
        for (id, popup) in popups where popup.isVisible { refreshPopup(id) }
    }

    /// Latest popup contents for an item, supplied by its provider.
    public func setPopupRows(_ rows: [PopupRow], for itemID: String) {
        popupRows[itemID] = rows
        if popups[itemID]?.isVisible == true { refreshPopup(itemID) }
    }

    // MARK: - Popups

    public func togglePopup(for itemID: String, config: Config, on displayID: CGDirectDisplayID = 0) {
        if popups[itemID]?.isVisible == true {
            closePopup(itemID)
        } else {
            openPopup(itemID, config: config, on: displayID)
        }
    }

    /// Opens a popup and renders it, for diagnostics.
    @discardableResult
    public func capturePopup(_ itemID: String, config: Config, to path: String) -> Bool {
        openPopup(itemID, config: config, on: NSScreen.main?.displayID ?? 0)
        guard let popup = popups[itemID] else { return false }
        return popup.capture(to: path)
    }

    public func closeAllPopups() {
        for id in popups.keys { closePopup(id) }
    }

    private func popupSpec(for itemID: String, in config: Config) -> PopupSpec? {
        config.allItems.first { $0.id == itemID }?.popup
    }

    private var popupConfig: Config?

    private var popupDisplay: [String: CGDirectDisplayID] = [:]

    private func openPopup(_ itemID: String, config: Config, on displayID: CGDirectDisplayID = 0) {
        guard let spec = popupSpec(for: itemID, in: config) else { return }
        // Only one open at a time; two popups on a status bar is never wanted.
        closeAllPopups()
        popupConfig = config
        popupDisplay[itemID] = displayID

        let popup = popups[itemID] ?? {
            let created = PopupWindow(itemID: itemID, config: self.config)
            created.onRowClick = { [weak self] item, row in
                guard let action = row.action else { return }
                self?.onPopupAction?(item, action)
            }
            created.onMouseExit = { [weak self] in
                guard let self, let spec = self.popupSpec(for: itemID, in: config) else { return }
                guard spec.dismiss.contains(.mouseExit) else { return }
                self.closePopup(itemID)
            }
            popups[itemID] = created
            return created
        }()

        refreshPopup(itemID)
        popup.show()
        installDismissal(for: itemID, spec: spec)
    }

    private func refreshPopup(_ itemID: String) {
        guard let popup = popups[itemID],
              let config = popupConfig,
              let spec = popupSpec(for: itemID, in: config),
              let display = popupDisplay[itemID].flatMap({ displays[$0] })
                ?? displays.values.first(where: { $0.lastLayout?.item(itemID) != nil })
                ?? displays.values.first,
              let frame = display.lastLayout?.item(itemID)
        else { return }

        // The anchor is the item's pill in screen coordinates.
        let box = frame.background == .zero ? frame.frame : frame.background
        let anchor = CGRect(
            x: display.panel.frame.minX + box.minX,
            y: display.panel.frame.minY + box.minY,
            width: box.width,
            height: box.height
        )

        popup.apply(
            rows: popupRows[itemID] ?? [],
            spec: spec,
            defaults: config.defaults,
            anchor: anchor,
            screen: display.screen,
            barConfig: self.config,
            contentsScale: BarDisplay.renderScale(for: display.screen)
        )
    }

    private func closePopup(_ itemID: String) {
        popups[itemID]?.hide()
        removeDismissal()
    }

    private func installDismissal(for itemID: String, spec: PopupSpec) {
        removeDismissal()

        if spec.dismiss.contains(.clickOutside) {
            // A global monitor sees clicks destined for other applications,
            // which is the only way to notice a click that never reaches us.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let mouse = NSEvent.mouseLocation
                    guard self.popups[itemID]?.contains(screenPoint: mouse) != true else { return }
                    self.closePopup(itemID)
                }
            }
        }

        for case .timeout(let seconds) in spec.dismiss {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.closePopup(itemID) }
            }
            popupTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func removeDismissal() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        popupTimeout?.cancel()
        popupTimeout = nil
    }

    private func redraw() {
        guard !isSuspended else { return }
        for display in displays.values {
            display.apply(nodes: nodes, config: config, measuring: measuring)
        }
    }

    // MARK: - Displays

    public func start() {
        syncDisplays()
        for display in displays.values { display.show() }
        redraw()
    }

    public func stop() {
        removeDismissal()
        for popup in popups.values { popup.close() }
        popups.removeAll()
        for display in displays.values { display.close() }
        displays.removeAll()
    }

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        switch config.displays {
        case .all:
            return all
        case .main:
            return NSScreen.main.map { [$0] } ?? Array(all.prefix(1))
        case .indices(let indices):
            return indices.compactMap { index in
                let zeroBased = index - 1
                return all.indices.contains(zeroBased) ? all[zeroBased] : nil
            }
        }
    }

    private func syncDisplays() {
        let screens = targetScreens()
        var live = Set<CGDirectDisplayID>()

        for screen in screens {
            guard let id = screen.displayID else { continue }
            live.insert(id)

            if let existing = displays[id] {
                existing.update(screen: screen)
                existing.reposition(config: config)
            } else {
                let display = BarDisplay(screen: screen, config: config)
                wire(display, id: id)
                displays[id] = display
                display.show()
            }
        }

        for (id, display) in displays where !live.contains(id) {
            display.close()
            displays.removeValue(forKey: id)
        }
    }

    private func wire(_ display: BarDisplay, id displayID: CGDirectDisplayID) {
        display.view.onMouseDown = { [weak self, weak display] point, button, _ in
            guard let self, let display, let id = display.hitTest(point) else { return }
            self.onEvent?(BarEvent(itemID: id, kind: .click(button), displayID: displayID))
        }
        display.view.onScroll = { [weak self, weak display] point, delta, precise in
            guard let self, let display, let id = display.hitTest(point) else { return }
            self.onEvent?(BarEvent(itemID: id, kind: .scroll(delta: delta, precise: precise), displayID: displayID))
        }
        display.view.onMouseMoved = { [weak self, weak display] point in
            guard let self, let display else { return }
            let id = point.flatMap { display.hitTest($0) }
            guard id != self.hovered else { return }
            if let previous = self.hovered {
                self.onEvent?(BarEvent(itemID: previous, kind: .hoverExit, displayID: displayID))
            }
            self.hovered = id
            if let id {
                self.onEvent?(BarEvent(itemID: id, kind: .hoverEnter))
            }
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncDisplays()
                self?.redraw()
            }
        }
    }

    // MARK: - Power

    /// Stops all drawing. Paired with `resume` on wake.
    public func suspend() {
        isSuspended = true
        closeAllPopups()
    }

    /// Rebuilds everything from scratch.
    ///
    /// A wake is the one moment where a full, forced pass is correct: display
    /// topology may have changed while asleep. Upstream's failure to do this is
    /// issues #783 and #776.
    public func resume() {
        isSuspended = false
        measuring.invalidate()
        syncDisplays()
        for display in displays.values {
            display.reposition(config: config)
            display.show()
        }
        redraw()
    }

    public var displayCount: Int { displays.count }

    /// Renders the main display's bar into a PNG.
    ///
    /// `CALayer.render(in:)` draws the tree into a bitmap we own, so this needs
    /// no Screen Recording grant and shows exactly what we draw, rather than a
    /// proxy for it. Every measurement short of this compares properties;
    /// this compares pixels.
    @discardableResult
    public func capture(to path: String, scale: CGFloat = 2) -> Bool {
        guard let display = (NSScreen.main?.displayID).flatMap({ displays[$0] })
                ?? displays.values.first,
              let layer = display.view.layer
        else { return false }

        let bounds = layer.bounds
        let pixelWidth = Int((bounds.width * scale).rounded(.up))
        let pixelHeight = Int((bounds.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else { return false }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }

        // A dark ground, so antialiased glyph edges read the way they do over
        // the real bar rather than over transparency.
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.32, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)

        layer.render(in: context)

        guard let image = context.makeImage() else { return false }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// The most recent layout for the main display, for diagnostics.
    ///
    /// Explicitly the main display: right-anchored items sit at
    /// `width - padding - content`, so reporting an arbitrary display would
    /// make every right-side coordinate incomparable with anything measured on
    /// another one.
    public var currentLayout: BarLayout? {
        if let mainID = NSScreen.main?.displayID, let display = displays[mainID] {
            return display.lastLayout
        }
        return displays.values.first?.lastLayout
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
