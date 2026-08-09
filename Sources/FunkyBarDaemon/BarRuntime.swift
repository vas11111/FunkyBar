import AppKit
import Foundation
import FunkyBarCore
import FunkyBarProviders
import FunkyBarRender

/// Owns the running bar: config, providers, the timer wheel and the windows.
@MainActor
final class BarRuntime {

    /// Set FUNKYBAR_DEBUG_EVENTS=1 to trace input and provider updates on
    /// stderr. Without it there is no way to tell "the event never arrived"
    /// from "the event arrived and changed nothing".
    private static let traceEvents = ProcessInfo.processInfo.environment["FUNKYBAR_DEBUG_EVENTS"] == "1"

    private let controller = BarController()
    private let wheel = TimerWheel()
    private var config = Config()
    private var providers: [String: any Provider] = [:]
    private var inputs = ConfigResolver.Inputs()
    private var configPath: String?
    private var configWatcher: DispatchSourceFileSystemObject?

    // MARK: - Lifecycle

    func start(configPath path: String?) throws {
        configPath = path
        try loadConfig()
        controller.onEvent = { [weak self] event in self?.handle(event) }
        controller.onPopupAction = { [weak self] itemID, action in
            self?.providers[itemID]?.handle(command: action)
            // The popup should reflect the result of what was just clicked, so
            // refresh the provider rather than wait for its next tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    guard let self, let provider = self.providers[itemID],
                          let update = provider.refresh() else { return }
                    self.ingest(update)
                    self.rebuild()
                }
            }
        }
        controller.start()
        observePower()
        watchConfig()
        rebuild()
    }

    func stop() {
        for provider in providers.values { provider.stop() }
        providers.removeAll()
        wheel.removeAll()
        configWatcher?.cancel()
        controller.stop()
    }

    // MARK: - Config

    @discardableResult
    func loadConfig() throws -> ConfigDiagnostics {
        guard let path = configPath else { return ConfigDiagnostics() }

        let source = try String(contentsOfFile: path, encoding: .utf8)
        let table: TOMLTable
        do {
            table = try TOMLParser.parse(source)
        } catch let diagnostics as ConfigDiagnostics {
            FileHandle.standardError.write(
                Data(diagnostics.render(path: path, source: source).utf8)
            )
            throw diagnostics
        }

        let outcome = ConfigDecoder.decode(table)
        if !outcome.diagnostics.isEmpty {
            FileHandle.standardError.write(
                Data(outcome.diagnostics.render(path: path, source: source).utf8)
            )
        }
        // Errors abort the reload; warnings never do, so a typo cannot take
        // the bar down.
        guard outcome.isUsable else { throw outcome.diagnostics }

        config = outcome.config
        controller.apply(config: config.bar)
        rebuildProviders()
        return outcome.diagnostics
    }

    /// Reloads on write, resolving symlinks first.
    ///
    /// Upstream requires the config to be an executable file and tries to
    /// `chmod` it, which breaks on a nix store symlink (#553). Here the config
    /// is data: it is read, never run, and the watch follows the link.
    private func watchConfig() {
        guard let path = configPath else { return }
        let resolved = (path as NSString).resolvingSymlinksInPath

        let descriptor = open(resolved, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An editor that writes via rename replaces the inode, so
                // re-establish the watch before reloading.
                self.configWatcher?.cancel()
                self.configWatcher = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    MainActor.assumeIsolated {
                        try? self.loadConfig()
                        self.rebuild()
                        self.watchConfig()
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        configWatcher = source
    }

    // MARK: - Providers

    private func rebuildProviders() {
        for provider in providers.values { provider.stop() }
        providers.removeAll()
        wheel.removeAll()

        for item in config.allItems {
            guard let binding = item.provider else { continue }
            // A repeated item shares one provider keyed by the template id.
            let templateID = item.repeatValue.map {
                String(item.id.dropLast($0.count + 1))
            } ?? item.id
            guard providers[templateID] == nil else { continue }

            let context = ProviderContext(
                itemID: templateID,
                options: binding.options,
                interval: binding.interval
            )
            guard let provider = Self.make(kind: binding.kind, context: context) else {
                FileHandle.standardError.write(
                    Data("funkybar: unknown provider '\(binding.kind)' for item '\(item.id)'\n".utf8)
                )
                continue
            }

            providers[templateID] = provider
            provider.start { [weak self] update in
                self?.ingest(update)
                self?.rebuild()
            }

            if let update = provider.refresh() { ingest(update) }

            if case .interval(let seconds) = provider.policy {
                wheel.register(id: templateID, interval: seconds) { [weak self, weak provider] in
                    guard let self, let provider, let update = provider.refresh() else { return }
                    self.ingest(update)
                    self.rebuild()
                }
            }
        }
    }

    private static func make(kind: String, context: ProviderContext) -> (any Provider)? {
        switch kind {
        case ClockProvider.kind:     ClockProvider(context)
        case FrontAppProvider.kind:  FrontAppProvider(context)
        case BatteryProvider.kind:   BatteryProvider(context)
        case AeroSpaceProvider.kind: AeroSpaceProvider(context)
        case PortsProvider.kind:     PortsProvider(context)
        case PushProvider.kind:      PushProvider(context)
        default: nil
        }
    }

    private func ingest(_ update: ProviderUpdate) {
        if Self.traceEvents {
            var parts = update.values.map { "\($0.key)=\($0.value)" }.sorted()
            // Per-clone values are where repeated items carry their data, so a
            // trace that omits them reports a coin update as empty.
            for (id, fields) in update.perItem.sorted(by: { $0.key < $1.key }) {
                let inner = fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
                parts.append("[\(id) \(inner)]")
            }
            let expansion = update.expansion.map { " expand=[\($0.joined(separator: ","))]" } ?? ""
            FileHandle.standardError.write(
                Data("update: \(update.itemID)  \(parts.joined(separator: " "))\(expansion)\n".utf8))
        }
        inputs.values[update.itemID] = update.values
        for (id, values) in update.perItem {
            inputs.values[id] = values
        }
        if let expansion = update.expansion {
            inputs.repeats[update.itemID] = expansion
        }
        if let rows = update.rows {
            controller.setPopupRows(rows, for: update.itemID)
        }
    }

    // MARK: - Drawing

    private var rebuildScheduled = false

    /// Coalesces several provider updates arriving in one turn into one layout
    /// pass, so a burst never causes a burst of redraws.
    func rebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildScheduled = false
                self.controller.apply(nodes: ConfigResolver.resolve(self.config, inputs: self.inputs))
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: BarEvent) {
        if Self.traceEvents {
            FileHandle.standardError.write(Data("event: \(event.itemID) \(event.kind)\n".utf8))
        }
        guard case .click(let button) = event.kind else { return }
        guard let item = config.allItems.first(where: { $0.id == event.itemID }) else {
            if Self.traceEvents {
                FileHandle.standardError.write(Data("  no item '\(event.itemID)'\n".utf8))
            }
            return
        }
        guard let action = item.actions[button] else {
            if Self.traceEvents {
                let available = item.actions.keys.map(\.rawValue).sorted().joined(separator: ", ")
                FileHandle.standardError.write(
                    Data("  no \(button.rawValue) action on '\(item.id)' (has: \(available))\n".utf8))
            }
            return
        }
        if Self.traceEvents {
            FileHandle.standardError.write(Data("  action: \(action)\n".utf8))
        }

        switch action {
        case .shell(let command):
            ProcessRunner(timeout: 10).run(command) { _ in }

        case .workspace(let template):
            let values = inputs.values[event.itemID] ?? [:]
            let workspace = template.render(values)
            guard !workspace.isEmpty else { return }
            ProcessRunner(timeout: 3).run("aerospace workspace \(workspace)") { _ in }

        case .provider(let name, let command):
            providers[name]?.handle(command: command)

        case .togglePopup:
            controller.togglePopup(for: event.itemID, config: config, on: event.displayID)
        }
    }

    // MARK: - Power

    /// Suspends everything while nothing is visible, and forces a full rebuild
    /// on wake.
    ///
    /// Upstream does neither, which is why items vanish after sleep (#783) and
    /// why it can hang against the display server with external displays
    /// attached (#776).
    private func observePower() {
        let workspace = NSWorkspace.shared.notificationCenter

        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.wheel.suspend()
                    self?.controller.suspend()
                }
            }
        }

        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.wheel.resume()
                    self.controller.resume()
                    for provider in self.providers.values {
                        if let update = provider.refresh() { self.ingest(update) }
                    }
                    self.rebuild()
                }
            }
        }
    }

    // MARK: - Introspection

    var displayCount: Int { controller.displayCount }

    @discardableResult
    func capture(to path: String) -> Bool { controller.capture(to: path) }

    @discardableResult
    func capturePopup(_ itemID: String, to path: String) -> Bool {
        controller.capturePopup(itemID, config: config, to: path)
    }

    /// What each item will actually draw, with provider values folded in.
    ///
    /// This is the diagnostic that catches wrong glyphs, empty labels and
    /// unresolved image paths without needing to look at the screen.
    /// Machine-readable form of `dump`, for funkybar-measure.
    var dumpJSON: String {
        let nodes = ConfigResolver.resolve(config, inputs: inputs)
        let layout = controller.currentLayout
        var entries: [String] = []

        func quote(_ s: String) -> String {
            var out = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                default:
                    // Control characters must be escaped; everything else goes
                    // out as raw UTF-8. A \u escape cannot carry a scalar above
                    // U+FFFF without a surrogate pair, and emitting five hex
                    // digits silently splits the glyph.
                    if c.value < 0x20 {
                        out += String(format: "\\u%04x", c.value)
                    } else {
                        out.unicodeScalars.append(c)
                    }
                }
            }
            return "\"\(out)\""
        }

        func font(_ f: FontSpec) -> String { "\(f.family):\(f.style):\(f.size)" }

        func emit(_ item: ResolvedItem) {
            let frame = layout?.item(item.id)
            var fields: [String] = []
            fields.append("\"id\":\(quote(item.id))")
            fields.append("\"kind\":\"item\"")
            if let frame {
                fields.append(String(format: "\"x\":%.2f,\"w\":%.2f", frame.frame.minX, frame.frame.width))
                fields.append(String(format: "\"bg_h\":%.2f", frame.background.height))
            }
            fields.append("\"icon\":\(quote(item.icon))")
            fields.append("\"icon_color\":\(quote(item.iconColor.hexString))")
            fields.append("\"icon_font\":\(quote(font(item.iconFont)))")
            fields.append("\"icon_drawing\":\(item.iconDrawing)")
            fields.append("\"label\":\(quote(item.label))")
            fields.append("\"label_color\":\(quote(item.labelColor.hexString))")
            fields.append("\"label_font\":\(quote(font(item.labelFont)))")
            fields.append("\"label_drawing\":\(item.labelDrawing)")
            fields.append("\"bg_drawing\":\(item.style.isVisible)")
            fields.append("\"bg_color\":\(quote(item.style.color.hexString))")
            fields.append("\"bg_border\":\(quote(item.style.borderColor.hexString))")
            fields.append(String(format: "\"bg_border_w\":%.2f", item.style.borderWidth))
            fields.append(String(format: "\"bg_radius\":%.2f", item.style.corner.radius))
            entries.append("{" + fields.joined(separator: ",") + "}")
        }

        for node in nodes {
            switch node {
            case .item(let item):
                emit(item)
            case .group(let group):
                let frame = layout?.group(group.id)
                var fields: [String] = ["\"id\":\(quote(group.id))", "\"kind\":\"group\""]
                if let frame {
                    fields.append(String(format: "\"x\":%.2f,\"w\":%.2f", frame.frame.minX, frame.frame.width))
                    fields.append(String(format: "\"bg_h\":%.2f", frame.background.height))
                }
                fields.append("\"bg_drawing\":\(group.style.isVisible)")
                fields.append("\"bg_color\":\(quote(group.style.color.hexString))")
                fields.append("\"bg_border\":\(quote(group.style.borderColor.hexString))")
                fields.append(String(format: "\"bg_border_w\":%.2f", group.style.borderWidth))
                fields.append(String(format: "\"bg_radius\":%.2f", group.style.corner.radius))
                entries.append("{" + fields.joined(separator: ",") + "}")
                for item in group.items { emit(item) }
            }
        }
        return "[" + entries.joined(separator: ",\n") + "]"
    }

    var dump: String {
        let nodes = ConfigResolver.resolve(config, inputs: inputs)
        let layout = controller.currentLayout
        var lines: [String] = []

        func box(_ id: String) -> String {
            guard let frame = layout?.item(id) ?? nil else { return "" }
            let f = frame.frame
            return String(format: "x=%.0f w=%.0f  ", f.minX, f.width)
        }

        func describe(_ item: ResolvedItem, indent: String) {
            var parts: [String] = []
            if item.hasIcon {
                let codes = item.icon.unicodeScalars
                    .map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                parts.append("icon=\(item.icon.debugDescription) [\(codes)]")
            }
            if item.hasLabel { parts.append("label=\(item.label.debugDescription)") }
            if let image = item.style.image {
                let path = image.resolvedPath ?? "<unresolved>"
                let exists = FileManager.default.fileExists(atPath: path) ? "ok" : "MISSING"
                parts.append("image=\(path) (\(exists), scale \(image.scale))")
            }
            if !item.style.isVisible && !item.hasIcon && !item.hasLabel {
                parts.append("<nothing to draw>")
            }
            lines.append("\(indent)\(item.id.padding(toLength: 20, withPad: " ", startingAt: 0)) "
                         + box(item.id) + parts.joined(separator: "  "))
        }

        for node in nodes {
            switch node {
            case .item(let item):
                describe(item, indent: "  ")
            case .group(let group):
                var groupBox = ""
                if let frame = layout?.group(group.id) {
                    groupBox = String(format: "  x=%.0f w=%.0f", frame.frame.minX, frame.frame.width)
                }
                lines.append("  [\(group.id)] \(group.position.rawValue)\(groupBox)")
                for item in group.items { describe(item, indent: "    ") }
            }
        }
        return lines.joined(separator: "\n")
    }

    var status: String {
        """
        displays:  \(controller.displayCount)
        items:     \(config.allItems.count)
        providers: \(providers.count) (\(providers.keys.sorted().joined(separator: ", ")))
        timers:    \(wheel.registeredCount) on a \(wheel.currentTickInterval)s shared tick
        suspended: \(wheel.isSuspended)
        """
    }
}
