import AppKit
import FunkyBarCore

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
        tree.setContentsScale(screen.backingScaleFactor)
    }

    static func frame(for screen: NSScreen, config: BarConfig) -> CGRect {
        let visible = screen.frame
        let width = visible.width - config.margin.horizontal
        let x = visible.minX + config.margin.leading

        let y: CGFloat
        switch config.edge {
        case .top:
            // `frame` includes the menu bar strip; sit just under the top edge.
            y = visible.maxY - config.height - config.margin.top
        case .bottom:
            y = visible.minY + config.margin.bottom
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
        tree.setContentsScale(screen.backingScaleFactor)
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
                wire(display)
                displays[id] = display
                display.show()
            }
        }

        for (id, display) in displays where !live.contains(id) {
            display.close()
            displays.removeValue(forKey: id)
        }
    }

    private func wire(_ display: BarDisplay) {
        display.view.onMouseDown = { [weak self, weak display] point, button, _ in
            guard let self, let display, let id = display.hitTest(point) else { return }
            self.onEvent?(BarEvent(itemID: id, kind: .click(button)))
        }
        display.view.onScroll = { [weak self, weak display] point, delta, precise in
            guard let self, let display, let id = display.hitTest(point) else { return }
            self.onEvent?(BarEvent(itemID: id, kind: .scroll(delta: delta, precise: precise)))
        }
        display.view.onMouseMoved = { [weak self, weak display] point in
            guard let self, let display else { return }
            let id = point.flatMap { display.hitTest($0) }
            guard id != self.hovered else { return }
            if let previous = self.hovered {
                self.onEvent?(BarEvent(itemID: previous, kind: .hoverExit))
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
