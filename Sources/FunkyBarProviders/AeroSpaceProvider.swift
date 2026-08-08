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
/// Two ways to drive it, in order of preference:
///
/// 1. **Push.** Add to `~/.config/aerospace/aerospace.toml`:
///
///        exec-on-workspace-change = ['/bin/bash', '-c',
///          'funkybar push aerospace focused=$AEROSPACE_FOCUSED_WORKSPACE']
///
///    Updates are then instant and the poll below can be relaxed to a minute.
///
/// 2. **Poll.** Without that hook, a modest interval keeps the bar correct.
///    Still one subprocess per tick rather than seven per switch.
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

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        policy = .interval(seconds: context.interval ?? 5)
        binary = context.string("binary") ?? "aerospace"
        // "no" hides empty workspaces, matching `--empty no`; "all" keeps them.
        emptyPolicy = context.string("empty") ?? "all"
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {
        self.emit = emit
    }

    /// A push from the AeroSpace hook: re-query immediately.
    public func handle(command: String) {
        query()
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

        // One invocation answers both questions. Upstream asks once per item.
        let listFlag = emptyPolicy == "no" ? "--monitor all --empty no" : "--monitor all"
        let command = """
        \(binary) list-workspaces \(listFlag) 2>/dev/null; \
        echo '---'; \
        \(binary) list-workspaces --focused 2>/dev/null
        """

        runner.run(command) { [weak self] result in
            let parsed: (all: [String], focused: String?)? = {
                guard case .success(let output) = result, output.succeeded else { return nil }
                let parts = output.standardOutput.components(separatedBy: "---")
                guard parts.count >= 2 else { return nil }
                let all = parts[0].split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let focused = parts[1].split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                return (all, focused)
            }()

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard let parsed, !parsed.all.isEmpty else { return }

                var update = ProviderUpdate(itemID: self.itemID)
                update.expansion = parsed.all
                update.values = ["focused": parsed.focused ?? ""]
                // One state per workspace, applied together, so the bar never
                // shows two highlighted workspaces mid-switch.
                for workspace in parsed.all {
                    update.perItem["\(self.itemID).\(workspace)"] = [
                        "workspace": workspace,
                        "state": workspace == parsed.focused ? "active" : "inactive",
                    ]
                }

                guard update != self.lastUpdate else { return }
                self.lastUpdate = update
                self.emit?(update)
            }
        }
    }
}

/// Receives values pushed over the socket, or seeded from a file at startup.
///
/// Replaces the state-file + `--trigger` + safety-poll pattern described in
/// INTEGRATION.md with one mechanism.
@MainActor
public final class PushProvider: Provider {
    public static let kind = "push"

    public let itemID: String
    public let policy: UpdatePolicy = .event
    public let channel: String

    private let seedFile: String?
    private let seedSeparator: String?
    private let seedKeys: [String]
    private let seedField: String
    private var emit: (@MainActor (ProviderUpdate) -> Void)?
    private var values: [String: String] = [:]
    private var perItem: [String: [String: String]] = [:]

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        channel = context.string("channel") ?? context.itemID
        seedFile = context.string("seed_file").map { ($0 as NSString).expandingTildeInPath }
        seedSeparator = context.string("seed_separator")
        seedKeys = context.strings("seed_keys") ?? []
        seedField = context.string("seed_field") ?? "value"
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {
        self.emit = emit
        seed()
    }

    /// Cold start from a state file, so the bar is honest before the app
    /// connects rather than blank.
    ///
    /// Two shapes are supported. A bare scalar (`status-state` holds `OFF`)
    /// becomes `state`/`value`. A delimited record (`meter` holds
    /// `75.85 1916.11 64943`) is split and mapped positionally onto
    /// `seed_keys`, so each clone of a repeated item gets its own field.
    private func seed() {
        guard let seedFile,
              let raw = try? String(contentsOfFile: seedFile, encoding: .utf8)
        else { return }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard !seedKeys.isEmpty else {
            values["state"] = text
            values["value"] = text
            return
        }

        // Default to whitespace, which is what `read -r a b c < file` does in
        // the shell plugin this replaces.
        let parts: [String]
        if let seedSeparator {
            parts = text.components(separatedBy: seedSeparator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
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
        ProviderUpdate(itemID: itemID, values: values, expansion: nil, perItem: perItem)
    }
}
