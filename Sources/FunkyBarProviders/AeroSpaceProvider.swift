import Foundation
import FunkyBarCore

/// Workspaces from AeroSpace.
///
/// Replaces `aerospace.sh`, which upstream runs **once per workspace item**:
/// seven forks and seven AeroSpace IPC round trips for a single switch, at
/// roughly 147 ms of latency. Worse, each of those seven scripts repaints
/// independently, which is what produces the flicker in issue #726.
///
/// Here one command answers the whole question, and every workspace layer is
/// updated inside a single transaction.
///
/// Driven by `aerospace subscribe --all`, which holds a socket open and emits
/// one JSON line per event:
///
///     {"_event":"focused-workspace-changed","prevWorkspace":"6","workspace":"3"}
///
/// So a workspace switch is a notification, not a poll, and the bar updates as
/// fast as the line arrives. A slow interval remains only to catch the
/// workspace *list* changing, which no event reports.
@MainActor
public final class AeroSpaceProvider: Provider {
    public static let kind = "aerospace"

    public let itemID: String
    public let policy: UpdatePolicy

    private let runner = ProcessRunner(timeout: 3)
    private let binary: String
    private let emptyPolicy: String
    private var emit: (@MainActor (ProviderUpdate) -> Void)?
    private var lastUpdate: ProviderUpdate?
    private var inFlight = false
    private var stream: StreamingProcess?
    /// Last focus reported by the event stream, applied without waiting for
    /// the workspace list to come back.
    private var focused: String?
    private var focusRevision: UInt64 = 0
    private var workspaces: [String] = []

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        // Only the workspace list needs polling, and it changes rarely.
        policy = .interval(seconds: context.interval ?? 60)
        binary = context.string("binary") ?? "aerospace"
        // "no" hides empty workspaces, matching `--empty no`; "all" keeps them.
        emptyPolicy = context.string("empty") ?? "all"
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {
        self.emit = emit

        let stream = StreamingProcess(executable: binary, arguments: ["subscribe", "--all"]) { [weak self] line in
            self?.handle(event: line)
        }
        stream.start()
        self.stream = stream
    }

    public func stop() {
        stream?.stop()
        stream = nil
        emit = nil
    }

    /// Applies one event line from `aerospace subscribe`.
    private func handle(event line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["_event"] as? String
        else { return }

        switch event {
        case "focused-workspace-changed", "focus-changed", "focused-monitor-changed":
            guard let workspace = object["workspace"] as? String else { return }
            // Repaint immediately from the event; do not wait on a subprocess.
            if workspace != focused {
                focused = workspace
                focusRevision &+= 1
                publish()
            }
            // A workspace can appear or empty as focus moves, so reconcile the
            // list too, but that is the slow path and never blocks the repaint.
            if !workspaces.contains(workspace) { query() }

        case "workspace-created", "workspace-destroyed", "monitor-added", "monitor-removed":
            query()

        default:
            break
        }
    }

    /// Emits from cached state, with no subprocess involved.
    private func publish() {
        var update = ProviderUpdate(itemID: itemID)
        update.expansion = workspaces
        update.values = ["focused": focused ?? ""]
        for workspace in workspaces {
            update.perItem["\(itemID).\(workspace)"] = [
                "workspace": workspace,
                "state": workspace == focused ? "active" : "inactive",
            ]
        }

        guard update != lastUpdate else { return }
        lastUpdate = update
        emit?(update)
    }

    public func refresh() -> ProviderUpdate? {
        query()
        // The subprocess is asynchronous, so hand back the previous answer and
        // let the callback deliver the fresh one. The bar never blocks on it.
        return lastUpdate
    }

    private func query() {
        guard !inFlight else { return }
        inFlight = true
        let revisionAtStart = focusRevision
        let binary = binary
        let runner = runner
        var arguments = ["list-workspaces", "--monitor", "all"]
        if emptyPolicy == "no" { arguments += ["--empty", "no"] }

        // Query once per provider, passing all inputs as arguments. Do not use
        // a shell or a delimiter that could also be a real workspace name.
        runner.run(executable: binary, arguments: arguments) { [weak self] result in
            guard case .success(let output) = result, output.succeeded else {
                Task { @MainActor [weak self] in self?.inFlight = false }
                return
            }
            let all = output.standardOutput.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            runner.run(executable: binary, arguments: ["list-workspaces", "--focused"]) { [weak self] result in
                let focus: String?
                let focusSucceeded: Bool
                if case .success(let output) = result, output.succeeded {
                    focusSucceeded = true
                    focus = output.standardOutput.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                } else {
                    focusSucceeded = false
                    focus = nil
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.inFlight = false
                    guard self.emit != nil else { return }
                    self.workspaces = all
                    // Polling still corrects focus when no stream is present,
                    // but never overwrites an event received during the query.
                    if focusSucceeded, self.focusRevision == revisionAtStart { self.focused = focus }
                    self.publish()
                }
            }
        }
    }
}

/// State written by another application.
///
/// Watches the state file rather than reading it once. An application that
/// already maintains a status file needs no changes: a write lands on the bar
/// immediately. Reading once at startup meant the bar showed whatever was true
/// when it launched and never moved again.
@MainActor
public final class PushProvider: Provider {
    public static let kind = "push"

    public let itemID: String
    public let policy: UpdatePolicy
    public let channel: String

    private let seedFile: String?
    private let seedSeparator: String?
    private let seedKeys: [String]
    private let seedField: String
    /// Named commands a click can invoke, e.g. `toggle` -> a shell line.
    private let commands: [String: String]
    private let runner = ProcessRunner(timeout: 10)
    private var emit: (@MainActor (ProviderUpdate) -> Void)?
    private var values: [String: String] = [:]
    private var perItem: [String: [String: String]] = [:]
    private var watcher: FileWatcher?

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        // Event-driven, with a slow floor so a missed write self-corrects.
        policy = .interval(seconds: context.interval ?? 10)
        channel = context.string("channel") ?? context.itemID
        seedFile = context.string("seed_file").map { ($0 as NSString).expandingTildeInPath }
        seedSeparator = context.string("seed_separator")
        seedKeys = context.strings("seed_keys") ?? []
        seedField = context.string("seed_field") ?? "value"

        var table: [String: String] = [:]
        if case .table(let entries)? = context.options["commands"]?.value {
            for (name, node) in entries.entries {
                if case .string(let line) = node.value { table[name] = line }
            }
        }
        commands = table
    }

    /// Runs the shell line bound to this command name.
    ///
    /// Until the socket layer lands this is how an external app is driven, and
    /// it is what makes `on_click = "status:toggle"` do something rather than
    /// silently resolve to nothing.
    public func handle(command: String) {
        guard let line = commands[command] else {
            if PushProvider.trace {
                let available = commands.keys.sorted().joined(separator: ", ")
                FileHandle.standardError.write(Data(
                    "command: '\(command)' not bound on '\(itemID)' (have: \(available))\n".utf8))
            }
            return
        }

        runner.run(line) { result in
            guard PushProvider.trace else { return }
            let report: String
            switch result {
            case .success(let output):
                report = "command: '\(command)' exit=\(output.status)"
                    + (output.timedOut ? " TIMED OUT" : "")
                    + (output.standardError.isEmpty ? "" : " stderr=\(output.standardError.prefix(200))")
            case .failure(let error):
                report = "command: '\(command)' failed to spawn: \(error)"
            }
            FileHandle.standardError.write(Data((report + "\n").utf8))
        }
    }

    nonisolated static let trace = ProcessInfo.processInfo.environment["FUNKYBAR_DEBUG_EVENTS"] == "1"

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {
        self.emit = emit
        seed()

        guard let seedFile else { return }
        let watcher = FileWatcher(path: seedFile) { [weak self] in
            guard let self else { return }
            self.seed()
            if let update = self.refresh() { self.emit?(update) }
        }
        watcher.start()
        self.watcher = watcher
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        emit = nil
    }

    /// Reads the current contents of the state file.
    ///
    /// Two shapes are supported. A bare scalar (a status file holding `OFF`)
    /// becomes `state`/`value`. A delimited record (a file holding
    /// `1.5 2.5 3.5`) is split and mapped positionally onto
    /// `seed_keys`, so each clone of a repeated item gets its own field.
    private func seed() {
        guard let seedFile,
              let raw = try? ConfigFile.readState(seedFile)
        else { return }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !seedKeys.isEmpty else {
            values["state"] = text
            values["value"] = text
            return
        }

        // A shortened record clears the omitted fields on the next snapshot.
        for key in seedKeys {
            perItem["\(itemID).\(key)"]?.removeValue(forKey: seedField)
            if perItem["\(itemID).\(key)"]?.isEmpty == true {
                perItem.removeValue(forKey: "\(itemID).\(key)")
            }
        }

        // Default to whitespace, which is what `read -r a b c < file` does in
        // the shell plugin this replaces.
        let parts: [String]
        if let seedSeparator {
            parts = text.components(separatedBy: seedSeparator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        }

        for (index, key) in seedKeys.enumerated() where index < parts.count {
            guard !parts[index].isEmpty else { continue }
            perItem["\(itemID).\(key)", default: [:]][seedField] = parts[index]
        }
    }

    /// Called by the IPC layer when something pushes to this channel.
    public func accept(values newValues: [String: String], forItem itemSuffix: String?) {
        if let itemSuffix {
            perItem["\(itemID).\(itemSuffix)", default: [:]].merge(newValues) { _, new in new }
        } else {
            values.merge(newValues) { _, new in new }
        }
        if let update = refresh() {
            emit?(update)
        }
    }

    public func refresh() -> ProviderUpdate? {
        // Re-read on every tick: this is the safety net for a write whose
        // event never arrived.
        seed()
        return ProviderUpdate(itemID: itemID, values: values, expansion: nil, perItem: perItem)
    }
}
