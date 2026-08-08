import CoreGraphics
import Foundation

// MARK: - Bar

public enum TopmostPolicy: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Above ordinary windows.
    case window
    /// Above everything, including other overlays.
    case all
    /// Ordinary window level.
    case off
}

public enum DisplaySelector: Equatable, Hashable, Sendable {
    case all
    case main
    case indices([Int])

    public static func parse(_ text: String) -> DisplaySelector? {
        switch text {
        case "all": return .all
        case "main", "primary": return .main
        default:
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let indices = parts.compactMap { Int($0) }
            guard !parts.isEmpty, indices.count == parts.count else { return nil }
            return .indices(indices)
        }
    }
}

public struct BarConfig: Equatable, Sendable {
    public var height: Double = 36
    public var edge: BarEdge = .top
    public var axis: Axis = .horizontal
    public var offset: Offset = .zero
    public var margin: Insets = .zero
    public var padding: Insets = Insets(horizontal: 10)
    public var color: Color = .clear
    public var corner: Corner = .square
    public var borderColor: Color = .clear
    public var borderWidth: Double = 0
    public var blurRadius: Double = 0
    public var displays: DisplaySelector = .all
    public var sticky: Bool = true
    public var topmost: TopmostPolicy = .window
    public var showInFullscreen: Bool = false
    /// Upstream issue #774: guard against brushing the screen edge by accident.
    public var hoverActivationDelay: Double = 0

    public init() {}
}

// MARK: - Visual specs

public struct ShadowSpec: Equatable, Sendable {
    public var color: Color = Color.black.withAlpha(0.5)
    public var radius: Double = 3
    public var offset: Offset = Offset(x: 0, y: -1)
    public var opacity: Double = 1

    public init() {}
}

public struct ImageSpec: Equatable, Sendable {
    public var path: String
    public var scale: Double = 1
    public var offset: Offset = .zero

    public init(path: String, scale: Double = 1, offset: Offset = .zero) {
        self.path = path
        self.scale = scale
        self.offset = offset
    }
}

/// The background box drawn behind an item or group.
public struct StyleSpec: Equatable, Sendable {
    public var drawing: Bool = true
    public var color: Color = .clear
    public var borderColor: Color = .clear
    public var borderWidth: Double = 0
    public var corner: Corner = .square
    /// `nil` means "size to content".
    ///
    /// Upstream issue #639: a bracket with no `background.height` vanishes.
    /// Here the absence of a height is a meaningful, supported state.
    public var height: Double?
    public var padding: Insets = .zero
    public var image: ImageSpec?
    public var shadow: ShadowSpec?

    public init() {}

    public var isVisible: Bool {
        drawing && (!color.isTransparent || (borderWidth > 0 && !borderColor.isTransparent) || image != nil)
    }
}

/// Icon or label.
public struct TextSpec: Equatable, Sendable {
    public var drawing: Bool = true
    public var template: Template = Template("")
    public var font: FontSpec = .systemDefault
    public var color: Color = .white
    public var padding: Insets = .zero
    public var offset: Offset = .zero
    /// Grapheme-cluster count, not bytes. Upstream issue #784 truncates CJK
    /// mid-character because it counts bytes.
    public var maxCharacters: Int?

    public init() {}

    public var isEmpty: Bool { !drawing || template.source.isEmpty }
}

// MARK: - Behaviour

public enum MouseButton: String, Equatable, Hashable, Sendable, CaseIterable {
    case left
    case right
    /// Upstream issue #681 has no way to report this.
    case middle
    case other
}

/// What a click does.
public enum Action: Equatable, Sendable {
    /// Run a shell command.
    case shell(String)
    /// Send a message to a provider, e.g. `status:toggle`.
    case provider(name: String, command: String)
    /// Toggle this item's popup.
    case togglePopup
    /// Switch AeroSpace workspace.
    case workspace(Template)
}

/// When a popup closes. Upstream issue #835 has no built-in dismissal, which
/// is why the user's ports item hand-rolls a `mouse.exited.global` handler.
public enum PopupDismissal: Equatable, Hashable, Sendable {
    case mouseExit
    case clickOutside
    case timeout(seconds: Double)
    case manual
}

public struct PopupSpec: Equatable, Sendable {
    public enum Trigger: String, Equatable, Sendable, CaseIterable {
        case click
        case hover
        case never
    }

    public var trigger: Trigger = .click
    public var dismiss: [PopupDismissal] = [.clickOutside]
    public var axis: Axis = .vertical
    public var style: StyleSpec = StyleSpec()
    public var alignment: Position = .left

    public init() {}
}

/// A named visual state, replacing the `case "$STATE" in` blocks in shell plugins.
public struct StateSpec: Equatable, Sendable {
    public var icon: Template?
    public var label: Template?
    public var color: Color?
    public var iconColor: Color?
    public var labelColor: Color?

    public init() {}
}

// MARK: - Provider binding

public struct ProviderBinding: Equatable, Sendable {
    /// Provider kind, e.g. `clock`, `battery`, `aerospace`, `command`, `push`.
    public var kind: String
    /// Poll interval in seconds; `nil` means the provider is event-driven.
    public var interval: Double?
    /// Provider-specific options, validated by the provider itself.
    public var options: TOMLTable

    public init(kind: String, interval: Double? = nil, options: TOMLTable = TOMLTable()) {
        self.kind = kind
        self.interval = interval
        self.options = options
    }
}

// MARK: - Items and groups

public enum WidthSpec: Equatable, Hashable, Sendable {
    case automatic
    case fixed(Double)
}

/// Generates several items from one declaration, replacing the shell `for`
/// loops that build workspace and coin pills today.
public enum RepeatSource: Equatable, Sendable {
    /// Fixed values, expanded at config load: `repeat = ["c", "b", "a"]`.
    case values([String])
    /// Provider-driven, expanded at runtime: `repeat = "workspace"`.
    ///
    /// The set is whatever the bound provider reports, so a workspace that
    /// appears or empties is reflected without a reload. Upstream issue #754 is
    /// exactly this staleness.
    case dynamic(String)
}

public struct ItemConfig: Equatable, Sendable {
    public var id: String
    public var position: Position = .left
    public var provider: ProviderBinding?
    public var icon: TextSpec = TextSpec()
    public var label: TextSpec = TextSpec()
    public var style: StyleSpec = StyleSpec()
    /// Outside the background; separates siblings.
    public var margin: Insets = .zero
    /// Inside the background; insets content.
    public var padding: Insets = .zero
    public var offset: Offset = .zero
    public var width: WidthSpec = .automatic
    public var drawing: Bool = true
    public var actions: [MouseButton: Action] = [:]
    public var states: [String: StateSpec] = [:]
    public var popup: PopupSpec?
    /// Set when the item was generated by `repeat`; carries the loop value.
    public var repeatValue: String?
    /// Present on an un-expanded template item.
    public var repeatSource: RepeatSource?
    /// Where this item was declared, for diagnostics.
    public var location: SourceLocation = .unknown

    public init(id: String) {
        self.id = id
    }
}

/// A bracket, but a real container node.
///
/// Upstream treats a bracket as a rectangle drawn behind a name list, which is
/// why it needs an explicit `background.height` (#639) and why its members'
/// outer margins get swallowed. A group here owns its children and computes
/// its own frame from them.
public struct GroupConfig: Equatable, Sendable {
    public var id: String
    public var position: Position = .left
    public var style: StyleSpec = StyleSpec()
    public var margin: Insets = .zero
    public var padding: Insets = .zero
    public var spacing: Double = 0
    public var drawing: Bool = true
    public var items: [ItemConfig] = []
    public var location: SourceLocation = .unknown

    public init(id: String) {
        self.id = id
    }
}

/// A top-level entry in the bar: either a bare item or a group of items.
public enum LayoutNode: Equatable, Sendable {
    case item(ItemConfig)
    case group(GroupConfig)

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

    public var location: SourceLocation {
        switch self {
        case .item(let item):   item.location
        case .group(let group): group.location
        }
    }
}

// MARK: - Defaults

/// Values inherited by every item unless overridden, replacing
/// `sketchybar --default`.
public struct DefaultsConfig: Equatable, Sendable {
    public var icon: TextSpec = TextSpec()
    public var label: TextSpec = TextSpec()
    public var style: StyleSpec = StyleSpec()
    public var margin: Insets = .zero
    public var padding: Insets = .zero

    public init() {}
}

// MARK: - Root

public struct Config: Equatable, Sendable {
    public var bar: BarConfig = BarConfig()
    public var defaults: DefaultsConfig = DefaultsConfig()
    public var nodes: [LayoutNode] = []

    public init() {}

    /// Nodes anchored to one end, in declaration order.
    ///
    /// Declaration order is visual order on both sides. Upstream inserts
    /// `right` items rightmost-first, which is why the user's sketchybarrc has
    /// to declare clock, battery, meter, status to get the opposite result.
    public func nodes(at position: Position) -> [LayoutNode] {
        nodes.filter { $0.position == position }
    }

    /// Every item in the tree, groups flattened.
    public var allItems: [ItemConfig] {
        nodes.flatMap { node -> [ItemConfig] in
            switch node {
            case .item(let item):   [item]
            case .group(let group): group.items
            }
        }
    }
}
