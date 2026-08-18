import AppKit
import FunkyBarCore

/// The bar's window.
///
/// One panel per display holding one layer tree, rather than upstream's one
/// SkyLight window per item. Everything here is public AppKit:
///
/// - `.nonactivatingPanel` so clicking the bar never steals focus
/// - `.canJoinAllSpaces` + `.stationary` for stickiness without a private
///   SkyLight space
/// - `.fullScreenAuxiliary` to appear over full-screen spaces
/// - `hasShadow = false`, since items draw their own
public final class BarPanel: NSPanel {

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    /// Accepting mouse events without activating is the whole point of a
    /// non-activating panel; without this, first clicks are swallowed.
    public override var acceptsFirstResponder: Bool { false }

    public init(frame: CGRect, config: BarConfig) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Click-through by default. The bar spans the full width of the
        // display, so a panel that accepts events everywhere swallows the whole
        // top edge: the auto-hidden menu bar never reveals and its items cannot
        // be clicked. BarController flips this to false only while the pointer
        // is actually over an item, which is the per-item interactivity
        // sketchybar gets from having one window per item.
        ignoresMouseEvents = true
        // Excluded from the window menu and from Exposé cycling.
        isExcludedFromWindowsMenu = true
        animationBehavior = .none

        apply(config)
    }

    /// Keeps the requested frame exactly.
    ///
    /// AppKit constrains a window below the menu-bar level out of the menu bar
    /// strip, which on a notched display pushed the bar from y=4 down to y=38
    /// the moment its level dropped below 24. The bar is meant to live in that
    /// strip, so opt out of the constraint rather than the level.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    public func apply(_ config: BarConfig) {
        level = Self.level(for: config.topmost)

        var behavior: NSWindow.CollectionBehavior = [.ignoresCycle, .stationary]
        if config.sticky {
            behavior.insert(.canJoinAllSpaces)
        } else {
            behavior.insert(.moveToActiveSpace)
        }
        if config.showInFullscreen {
            behavior.insert(.fullScreenAuxiliary)
        }
        collectionBehavior = behavior
    }

    static func level(for policy: TopmostPolicy) -> NSWindow.Level {
        switch policy {
        case .off:
            return .normal
        case .window:
            // Below the menu bar, not above it. Sitting at .statusWindow (25)
            // puts the bar over the system menu bar (24), so an auto-hidden
            // menu bar reveals *underneath* the bar and cannot be used.
            return NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        case .all:
            return NSWindow.Level(Int(CGWindowLevelForKey(.maximumWindow)))
        }
    }
}

/// Hosts the layer tree and turns AppKit events into bar events.
public final class BarView: NSView {

    public var onMouseDown: ((CGPoint, MouseButton, NSEvent.ModifierFlags) -> Void)?
    public var onScroll: ((CGPoint, CGFloat, Bool) -> Void)?
    public var onMouseMoved: ((CGPoint?) -> Void)?

    private var trackingArea: NSTrackingArea?

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { false }
    /// Deliver the first click without requiring the window to activate first.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Events

    public override func mouseDown(with event: NSEvent) {
        report(event, button: .left)
    }

    public override func rightMouseDown(with event: NSEvent) {
        report(event, button: .right)
    }

    public override func otherMouseDown(with event: NSEvent) {
        // Upstream has no representation for this at all (#681).
        report(event, button: event.buttonNumber == 2 ? .middle : .other)
    }

    private func report(_ event: NSEvent, button: MouseButton) {
        onMouseDown?(convert(event.locationInWindow, from: nil), button, event.modifierFlags)
    }

    public override func scrollWheel(with event: NSEvent) {
        // Reporting precision lets a config distinguish a mouse wheel from a
        // trackpad, which upstream cannot (#521, #535).
        onScroll?(
            convert(event.locationInWindow, from: nil),
            event.scrollingDeltaY,
            event.hasPreciseScrollingDeltas
        )
    }

    public override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        onMouseMoved?(nil)
    }
}
