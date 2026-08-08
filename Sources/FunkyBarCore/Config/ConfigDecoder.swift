import Foundation

/// Turns a token-resolved TOML tree into a validated `Config`.
///
/// Decoding never stops at the first problem: every accessor records a located
/// diagnostic and returns nil, so one run reports everything wrong with a file.
public enum ConfigDecoder {

    public struct Outcome: Sendable {
        public let config: Config
        public let diagnostics: ConfigDiagnostics

        public var isUsable: Bool { !diagnostics.hasErrors }
    }

    private static let rootKeys: Set<String> = ["bar", "theme", "defaults", "item", "group"]

    public static func decode(_ root: TOMLTable) -> Outcome {
        var diagnostics = ConfigDiagnostics()
        let resolved = TokenResolver.resolve(root, diagnostics: &diagnostics)

        let sink = DiagnosticSink()
        let reader = ConfigReader(table: resolved, path: "", sink: sink)
        reader.warnUnknownKeys(rootKeys)

        var config = Config()

        if let bar = reader.child("bar") {
            config.bar = decodeBar(bar)
        }

        let defaults = reader.child("defaults").map(decodeDefaults) ?? DefaultsConfig()
        config.defaults = defaults

        // TOML groups all `[[item]]` under one key and all `[[group]]` under
        // another, so declaration order between the two is only recoverable
        // from source position. Sorting by location restores what the user
        // actually wrote, which is also the render order.
        var nodes: [LayoutNode] = []

        for itemReader in reader.children("item") {
            nodes.append(contentsOf: decodeItems(itemReader, defaults: defaults).map(LayoutNode.item))
        }
        for groupReader in reader.children("group") {
            if let group = decodeGroup(groupReader, defaults: defaults) {
                nodes.append(.group(group))
            }
        }

        nodes.sort { lhs, rhs in
            (lhs.location.line, lhs.location.column) < (rhs.location.line, rhs.location.column)
        }
        config.nodes = nodes

        validateUniqueIDs(config, sink: sink)

        var all = diagnostics
        all.merge(sink.diagnostics)
        return Outcome(config: config, diagnostics: all)
    }

    // MARK: - Bar

    private static let barKeys: Set<String> = [
        "height", "edge", "position", "axis", "offset", "margin", "padding", "color",
        "corner_radius", "corner", "border_color", "border_width", "blur_radius",
        "displays", "sticky", "topmost", "show_in_fullscreen", "hover", "font_smoothing",
    ]

    private static func decodeBar(_ reader: ConfigReader) -> BarConfig {
        reader.warnUnknownKeys(barKeys)
        var bar = BarConfig()

        if let value = reader.length("height") { bar.height = value }
        if let edge = reader.enumeration("edge", as: BarEdge.self) { bar.edge = edge }
        // `position` is the sketchybarrc spelling; accept it as an alias.
        if reader.has("position"), let edge = reader.enumeration("position", as: BarEdge.self) {
            bar.edge = edge
        }
        if let axis = reader.enumeration("axis", as: Axis.self) { bar.axis = axis }
        if let offset = reader.offset("offset") { bar.offset = offset }
        if let insets = reader.insets("margin") { bar.margin = insets }
        if let insets = reader.insets("padding") { bar.padding = insets }
        if let color = reader.color("color") { bar.color = color }
        if let color = reader.color("border_color") { bar.borderColor = color }
        if let value = reader.length("border_width") { bar.borderWidth = value }
        if let value = reader.length("blur_radius") { bar.blurRadius = value }
        if let value = reader.length("corner_radius") { bar.corner.radius = value }
        if let corner = reader.child("corner") { bar.corner = decodeCorner(corner, base: bar.corner) }
        if let sticky = reader.bool("sticky") { bar.sticky = sticky }
        if let topmost = reader.enumeration("topmost", as: TopmostPolicy.self) { bar.topmost = topmost }
        if let value = reader.bool("show_in_fullscreen") { bar.showInFullscreen = value }
        if let value = reader.bool("font_smoothing") { bar.fontSmoothing = value }

        if let text = reader.string("displays") {
            if let selector = DisplaySelector.parse(text) {
                bar.displays = selector
            } else {
                reader.sink.error(
                    "'bar.displays' is not a valid selector: \"\(text)\"",
                    at: reader.location,
                    hint: "use \"all\", \"main\", or a comma-separated list like \"1,2\""
                )
            }
        }

        if let hover = reader.child("hover") {
            hover.warnUnknownKeys(["activation_delay"])
            if let delay = hover.duration("activation_delay") { bar.hoverActivationDelay = delay }
        }

        return bar
    }

    // MARK: - Defaults

    private static let defaultsKeys: Set<String> = ["icon", "label", "style", "margin", "padding"]

    private static func decodeDefaults(_ reader: ConfigReader) -> DefaultsConfig {
        reader.warnUnknownKeys(defaultsKeys)
        var defaults = DefaultsConfig()

        if let icon = reader.child("icon") { defaults.icon = decodeText(icon, base: defaults.icon) }
        if let label = reader.child("label") { defaults.label = decodeText(label, base: defaults.label) }
        if let style = reader.child("style") { defaults.style = decodeStyle(style, base: defaults.style) }
        if let insets = reader.insets("margin") { defaults.margin = insets }
        if let insets = reader.insets("padding") { defaults.padding = insets }

        return defaults
    }

    // MARK: - Visual specs

    private static let textKeys: Set<String> = [
        "drawing", "text", "string", "font", "color", "padding", "offset", "max_chars",
    ]

    private static func decodeText(_ reader: ConfigReader, base: TextSpec) -> TextSpec {
        reader.warnUnknownKeys(textKeys)
        var spec = base

        if let drawing = reader.bool("drawing") { spec.drawing = drawing }
        // `string` is the sketchybarrc spelling.
        if let text = reader.string("text") ?? reader.string("string") {
            spec.template = Template(text)
        }
        if let font = reader.font("font") { spec.font = font }
        if let color = reader.color("color") { spec.color = color }
        if let insets = reader.insets("padding") { spec.padding = insets }
        if let offset = reader.offset("offset") { spec.offset = offset }
        if let max = reader.int("max_chars") { spec.maxCharacters = max }

        return spec
    }

    private static let styleKeys: Set<String> = [
        "drawing", "color", "border_color", "border_width", "corner_radius", "corner",
        "height", "padding", "image", "shadow",
    ]

    private static func decodeStyle(_ reader: ConfigReader, base: StyleSpec) -> StyleSpec {
        reader.warnUnknownKeys(styleKeys)
        var spec = base

        if let drawing = reader.bool("drawing") { spec.drawing = drawing }
        if let color = reader.color("color") { spec.color = color }
        if let color = reader.color("border_color") { spec.borderColor = color }
        if let value = reader.length("border_width") { spec.borderWidth = value }
        if let value = reader.length("corner_radius") { spec.corner.radius = value }
        if let corner = reader.child("corner") { spec.corner = decodeCorner(corner, base: spec.corner) }
        // Absent height means "size to content"; that is a real state, not a bug.
        if let value = reader.length("height") { spec.height = value }
        if let insets = reader.insets("padding") { spec.padding = insets }
        if let image = reader.child("image") { spec.image = decodeImage(image) }
        if let shadow = reader.child("shadow") { spec.shadow = decodeShadow(shadow, base: spec.shadow) }

        return spec
    }

    private static func decodeCorner(_ reader: ConfigReader, base: Corner) -> Corner {
        reader.warnUnknownKeys(["radius", "style"])
        var corner = base
        if let value = reader.length("radius") { corner.radius = value }
        if let style = reader.enumeration("style", as: CornerStyle.self) { corner.style = style }
        return corner
    }

    private static func decodeImage(_ reader: ConfigReader) -> ImageSpec? {
        reader.warnUnknownKeys(["path", "scale", "offset"])
        guard let path = reader.string("path") else {
            reader.sink.error("image needs a 'path'", at: reader.location)
            return nil
        }
        // The tilde is expanded after field substitution, since a template
        // could in principle produce the leading "~".
        var image = ImageSpec(path: Template(path))
        if let scale = reader.length("scale") { image.scale = scale }
        if let offset = reader.offset("offset") { image.offset = offset }
        return image
    }

    private static func decodeShadow(_ reader: ConfigReader, base: ShadowSpec?) -> ShadowSpec {
        reader.warnUnknownKeys(["color", "radius", "offset", "opacity"])
        var shadow = base ?? ShadowSpec()
        if let color = reader.color("color") { shadow.color = color }
        if let value = reader.length("radius") { shadow.radius = value }
        if let offset = reader.offset("offset") { shadow.offset = offset }
        if let value = reader.double("opacity") { shadow.opacity = min(1, max(0, value)) }
        return shadow
    }

    // MARK: - Items

    private static let itemKeys: Set<String> = [
        "id", "position", "provider", "interval", "icon", "label", "style", "margin",
        "padding", "offset", "width", "drawing", "on_click", "states", "popup", "repeat",
    ]

    /// Returns one item, or several when `repeat` holds fixed values.
    private static func decodeItems(_ reader: ConfigReader, defaults: DefaultsConfig) -> [ItemConfig] {
        reader.warnUnknownKeys(itemKeys)

        let providerKind = reader.isTable("provider")
            ? reader.child("provider")?.string("kind")
            : reader.string("provider")
        let explicitID = reader.string("id")

        guard let baseID = explicitID ?? providerKind else {
            reader.sink.error(
                "an item needs an 'id' or a 'provider'",
                at: reader.location,
                hint: "add id = \"something\""
            )
            return []
        }

        var item = ItemConfig(id: baseID)
        item.location = reader.location
        item.icon = defaults.icon
        item.label = defaults.label
        item.style = defaults.style
        item.margin = defaults.margin
        item.padding = defaults.padding

        if let position = reader.enumeration("position", as: Position.self) { item.position = position }
        if let drawing = reader.bool("drawing") { item.drawing = drawing }
        if let insets = reader.insets("margin") { item.margin = insets }
        if let insets = reader.insets("padding") { item.padding = insets }
        if let offset = reader.offset("offset") { item.offset = offset }
        if let width = reader.length("width") { item.width = .fixed(width) }

        if reader.isTable("icon"), let icon = reader.child("icon") {
            item.icon = decodeText(icon, base: item.icon)
        } else if let text = reader.string("icon") {
            item.icon.template = Template(text)
        }

        if reader.isTable("label"), let label = reader.child("label") {
            item.label = decodeText(label, base: item.label)
        } else if let text = reader.string("label") {
            item.label.template = Template(text)
        }

        if let style = reader.child("style") { item.style = decodeStyle(style, base: item.style) }
        if let provider = decodeProvider(reader, kind: providerKind) { item.provider = provider }
        if let actions = reader.child("on_click") { item.actions = decodeActions(actions) }
        if let states = reader.child("states") { item.states = decodeStates(states) }
        if reader.isTable("popup"), let popup = reader.child("popup") { item.popup = decodePopup(popup) }
        else if let trigger = reader.string("popup") {
            var spec = PopupSpec()
            spec.trigger = PopupSpec.Trigger(rawValue: trigger) ?? .click
            item.popup = spec
        }

        // `repeat` expansion.
        guard let node = reader.table["repeat"] else { return [item] }

        switch node.value {
        case .array:
            guard let values = reader.strings("repeat") else { return [item] }
            guard !values.isEmpty else {
                reader.sink.warn("'repeat' is empty, so this item renders nothing", at: node.location)
                return []
            }
            return values.map { value in
                var clone = item
                clone.id = "\(baseID).\(value)"
                clone.repeatValue = value
                clone.repeatSource = .values(values)
                return clone
            }

        case .string(let source):
            item.repeatSource = .dynamic(source)
            return [item]

        default:
            reader.sink.error(
                "'repeat' should be an array of values or a provider field name",
                at: node.location,
                hint: "for example repeat = [\"btc\", \"eth\"] or repeat = \"workspace\""
            )
            return [item]
        }
    }

    private static func decodeProvider(_ reader: ConfigReader, kind: String?) -> ProviderBinding? {
        guard let kind else { return nil }

        var options = TOMLTable()
        if reader.isTable("provider"), let child = reader.child("provider") {
            options = child.table
        } else {
            // Provider options may sit inline on the item; carry across
            // anything the item schema does not claim.
            for (key, node) in reader.table.entries where !itemKeys.contains(key) {
                options.insert(node, for: key)
            }
        }

        var binding = ProviderBinding(kind: kind, options: options)
        if let interval = reader.duration("interval") { binding.interval = interval }
        return binding
    }

    private static func decodeActions(_ reader: ConfigReader) -> [MouseButton: Action] {
        reader.warnUnknownKeys(Set(MouseButton.allCases.map(\.rawValue))
            .union(["shell", "command", "workspace", "popup", "provider"]))

        var actions: [MouseButton: Action] = [:]

        // Shorthand: on_click = { workspace = "1" } applies to the left button.
        if let action = decodeAction(reader) {
            actions[.left] = action
        }

        for button in MouseButton.allCases {
            if reader.isTable(button.rawValue), let child = reader.child(button.rawValue) {
                if let action = decodeAction(child) { actions[button] = action }
            } else if let text = reader.string(button.rawValue) {
                actions[button] = parseActionString(text)
            }
        }

        return actions
    }

    private static func decodeAction(_ reader: ConfigReader) -> Action? {
        if let command = reader.string("shell") ?? reader.string("command") {
            return .shell(command)
        }
        if let workspace = reader.string("workspace") {
            return .workspace(Template(workspace))
        }
        if reader.isString("popup") || reader.bool("popup") == true {
            return .togglePopup
        }
        if let text = reader.string("provider") {
            return parseActionString(text)
        }
        return nil
    }

    /// `"status:toggle"` addresses a provider; anything else is a shell command.
    private static func parseActionString(_ text: String) -> Action {
        if text == "popup" { return .togglePopup }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") {
            return .provider(name: String(parts[0]), command: String(parts[1]))
        }
        return .shell(text)
    }

    private static func decodeStates(_ reader: ConfigReader) -> [String: StateSpec] {
        var states: [String: StateSpec] = [:]

        for (name, node) in reader.table.entries {
            guard case .table(let child) = node.value else {
                reader.sink.error(
                    "state '\(name)' should be a table",
                    at: node.location,
                    hint: "for example [item.states.ON] or states.ON = { label = \"STATUS\" }"
                )
                continue
            }
            let stateReader = ConfigReader(table: child, path: "\(reader.path).\(name)", sink: reader.sink)
            stateReader.warnUnknownKeys(["icon", "label", "color", "icon_color", "label_color"])

            var state = StateSpec()
            if let icon = stateReader.string("icon") { state.icon = Template(icon) }
            if let label = stateReader.string("label") { state.label = Template(label) }
            if let color = stateReader.color("color") { state.color = color }
            if let color = stateReader.color("icon_color") { state.iconColor = color }
            if let color = stateReader.color("label_color") { state.labelColor = color }
            states[name] = state
        }

        return states
    }

    private static func decodePopup(_ reader: ConfigReader) -> PopupSpec {
        reader.warnUnknownKeys(["on", "trigger", "dismiss", "axis", "style", "alignment"])
        var popup = PopupSpec()

        if let trigger = reader.enumeration("on", as: PopupSpec.Trigger.self) { popup.trigger = trigger }
        if reader.has("trigger"), let trigger = reader.enumeration("trigger", as: PopupSpec.Trigger.self) {
            popup.trigger = trigger
        }
        if let axis = reader.enumeration("axis", as: Axis.self) { popup.axis = axis }
        if let alignment = reader.enumeration("alignment", as: Position.self) { popup.alignment = alignment }
        if let style = reader.child("style") { popup.style = decodeStyle(style, base: popup.style) }

        if let raw = reader.strings("dismiss") {
            var dismissals: [PopupDismissal] = []
            for entry in raw {
                switch entry {
                case "mouse_exit":    dismissals.append(.mouseExit)
                case "click_outside": dismissals.append(.clickOutside)
                case "manual":        dismissals.append(.manual)
                default:
                    if entry.hasPrefix("timeout:"),
                       let seconds = ConfigReader.parseDuration(String(entry.dropFirst(8))) {
                        dismissals.append(.timeout(seconds: seconds))
                    } else {
                        reader.sink.error(
                            "'\(entry)' is not a valid popup dismissal",
                            at: reader.location,
                            hint: "expected \"mouse_exit\", \"click_outside\", \"manual\", or \"timeout:5s\""
                        )
                    }
                }
            }
            if !dismissals.isEmpty { popup.dismiss = dismissals }
        }

        return popup
    }

    // MARK: - Groups

    private static let groupKeys: Set<String> = [
        "id", "position", "style", "margin", "padding", "spacing", "drawing", "item",
    ]

    private static func decodeGroup(_ reader: ConfigReader, defaults: DefaultsConfig) -> GroupConfig? {
        reader.warnUnknownKeys(groupKeys)

        guard let id = reader.string("id") else {
            reader.sink.error("a group needs an 'id'", at: reader.location)
            return nil
        }

        var group = GroupConfig(id: id)
        group.location = reader.location

        if let position = reader.enumeration("position", as: Position.self) { group.position = position }
        if let style = reader.child("style") { group.style = decodeStyle(style, base: group.style) }
        if let insets = reader.insets("margin") { group.margin = insets }
        if let insets = reader.insets("padding") { group.padding = insets }
        if let spacing = reader.length("spacing") { group.spacing = spacing }
        if let drawing = reader.bool("drawing") { group.drawing = drawing }

        for itemReader in reader.children("item") {
            var items = decodeItems(itemReader, defaults: defaults)
            // A group owns its children's placement; per-item position is
            // meaningless inside one.
            for index in items.indices { items[index].position = group.position }
            group.items.append(contentsOf: items)
        }

        if group.items.isEmpty {
            reader.sink.warn("group '\(id)' has no items", at: reader.location)
        }

        return group
    }

    // MARK: - Validation

    private static func validateUniqueIDs(_ config: Config, sink: DiagnosticSink) {
        var seen: [String: SourceLocation] = [:]

        func check(_ id: String, at location: SourceLocation) {
            if let first = seen[id] {
                sink.error(
                    "duplicate id '\(id)'",
                    at: location,
                    hint: "first used at line \(first.line); ids address items from the CLI, so they must be unique"
                )
            } else {
                seen[id] = location
            }
        }

        for node in config.nodes {
            switch node {
            case .item(let item):
                check(item.id, at: item.location)
            case .group(let group):
                check(group.id, at: group.location)
                for item in group.items { check(item.id, at: item.location) }
            }
        }
    }
}
