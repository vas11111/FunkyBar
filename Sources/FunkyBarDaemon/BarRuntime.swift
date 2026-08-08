import AppKit
import Foundation
import FunkyBarCore
import FunkyBarProviders
import FunkyBarRender

/// Owns the running bar: config, providers, the timer wheel and the windows.
@MainActor
final class BarRuntime {

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
        inputs.values[update.itemID] = update.values
        for (id, values) in update.perItem {
            inputs.values[id] = values
        }
        if let expansion = update.expansion {
            inputs.repeats[update.itemID] = expansion
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
        guard case .click(let button) = event.kind else { return }
        guard let item = config.allItems.first(where: { $0.id == event.itemID }) else { return }
        guard let action = item.actions[button] ?? (button == .left ? item.actions[.left] : nil) else { return }

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
            break   // popups land in M2
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
