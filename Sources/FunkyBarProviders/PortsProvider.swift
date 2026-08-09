import Darwin
import Foundation
import FunkyBarCore

/// Listening TCP ports and watched processes, read in-process.
///
/// This is the headline efficiency case. `ports.sh` shells out to
/// `lsof -nP -iTCP:... -sTCP:LISTEN`, plus two `pgrep`s, an `awk`, a `sort` and
/// (when the popup is open) a `python3` to parse JSON, twelve times a minute.
/// Measured: **94 ms of CPU per invocation, 1.88% of a P-core sustained, about
/// 82% of everything the current bar costs.**
///
/// `lsof` is slow because it stats every descriptor of every process and then
/// filters. Asking the kernel only for socket descriptors and filtering on
/// `TSI_S_LISTEN` does the same job without a fork, an exec, or a parse.
@MainActor
public final class PortsProvider: Provider {
    public static let kind = "ports"

    public let itemID: String
    public let policy: UpdatePolicy

    private let watchedPorts: Set<UInt16>
    private let watchedProcesses: [String]
    private var lastScan: Scan?

    private static let okColor = (try? Color.parse("#56d364").get()) ?? .white
    private static let idleColor = (try? Color.parse("#6e7681").get()) ?? .white
    private static let textColor = (try? Color.parse("#f1d9a4").get()) ?? .white

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        policy = .interval(seconds: context.interval ?? 5)
        watchedPorts = Set((context.ints("ports") ?? []).compactMap { UInt16(exactly: $0) })
        watchedProcesses = context.strings("watch") ?? []
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {}

    public func refresh() -> ProviderUpdate? {
        let scan = Self.scan(ports: watchedPorts, processes: Set(watchedProcesses))
        lastScan = scan

        var parts: [String] = []
        for name in watchedProcesses where scan.runningProcesses.contains(name) {
            // Caps only: every other label on the bar is caps or digits, and
            // lowercase descenders make a label sit optically lower.
            parts.append(name.uppercased())
        }
        if !scan.listening.isEmpty { parts.append("\(scan.listening.count)P") }

        let state: String
        if !scan.runningProcesses.isEmpty { state = "chain" }
        else if !scan.listening.isEmpty { state = "ports" }
        else { state = "idle" }

        return ProviderUpdate(
            itemID: itemID,
            values: [
                "label": parts.isEmpty ? "IDLE" : parts.joined(separator: "·"),
                "state": state,
                "count": String(scan.listening.count),
                "ports": scan.listening.map { String($0.port) }.sorted().joined(separator: ","),
            ],
            rows: rows(for: scan)
        )
    }

    /// Popup contents: watched processes first, then every listening port.
    ///
    /// Replaces ports_click.sh, which rebuilt the rows by removing and
    /// re-adding sketchybar items on every open, and ports_kill.sh, which
    /// shelled out to lsof again to find what to kill. The scan already knows
    /// the pid, so a row carries it and the kill needs no second lookup.
    private func rows(for scan: Scan) -> [PopupRow] {
        var out: [PopupRow] = []

        for name in watchedProcesses {
            let running = scan.runningProcesses.contains(name)
            out.append(PopupRow(
                id: "proc.\(name)",
                icon: name,
                label: running ? "running ✕" : "stopped",
                color: running ? Self.okColor : Self.idleColor,
                action: running ? "kill:name:\(name)" : nil
            ))
        }

        for listener in scan.listening.sorted(by: { $0.port < $1.port }) {
            out.append(PopupRow(
                id: "port.\(listener.port)",
                icon: String(listener.port),
                label: "\(listener.process) ✕",
                color: Self.textColor,
                action: "kill:pid:\(listener.pid)"
            ))
        }

        if out.isEmpty {
            out.append(PopupRow(id: "none", icon: "—", label: "nothing listening", color: Self.idleColor))
        }
        return out
    }

    /// `kill:name:<proc>` or `kill:pid:<pid>`, sent by a popup row click.
    ///
    /// TERM first, KILL if it survives, matching ports_kill.sh, but without
    /// re-deriving the target: the row already carries it.
    public func handle(command: String) {
        let parts = command.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "kill" else { return }

        let target = parts[2]
        let command: String
        switch parts[1] {
        case "pid":
            guard let pid = Int32(target) else { return }
            command = "kill \(pid) 2>/dev/null; sleep 2; kill -9 \(pid) 2>/dev/null; true"
        case "name":
            command = "pkill -x '\(target)' 2>/dev/null; sleep 2; pkill -9 -x '\(target)' 2>/dev/null; true"
        default:
            return
        }

        ProcessRunner(timeout: 8).run(command) { _ in }
    }

    // MARK: - Scanning

    public struct Listener: Hashable, Sendable {
        public let port: UInt16
        public let pid: pid_t
        public let process: String
    }

    public struct Scan: Sendable {
        public var listening: Set<Listener>
        public var runningProcesses: Set<String>
    }

    /// Walks every process's socket descriptors once.
    ///
    /// Exposed so `funkybar doctor` and the popup builder can reuse one scan
    /// rather than each running its own.
    public nonisolated static func scan(ports: Set<UInt16>, processes: Set<String>) -> Scan {
        var listening = Set<Listener>()
        var running = Set<String>()

        // Ask for the buffer size first; the process list changes between
        // calls, so over-allocate rather than assume.
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return Scan(listening: [], runningProcesses: []) }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else { return Scan(listening: [], runningProcesses: []) }
        let count = Int(written) / MemoryLayout<pid_t>.size

        for index in 0 ..< count {
            let pid = pids[index]
            guard pid > 0 else { continue }

            let name = processName(pid)
            if !name.isEmpty, processes.contains(name) { running.insert(name) }

            // Skip the descriptor walk entirely when no ports are watched.
            guard !ports.isEmpty else { continue }

            for port in listeningPorts(pid, wanted: ports) {
                listening.insert(Listener(port: port, pid: pid, process: name))
            }
        }

        return Scan(listening: listening, runningProcesses: running)
    }

    private nonisolated static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private nonisolated static func listeningPorts(_ pid: pid_t, wanted: Set<UInt16>) -> [UInt16] {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let capacity = Int(byteCount) / MemoryLayout<proc_fdinfo>.size
        guard capacity > 0 else { return [] }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &descriptors,
            Int32(capacity * MemoryLayout<proc_fdinfo>.size)
        )
        guard written > 0 else { return [] }

        var found: [UInt16] = []
        for index in 0 ..< Int(written) / MemoryLayout<proc_fdinfo>.size {
            let descriptor = descriptors[index]
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }

            var info = socket_fdinfo()
            let size = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                &info, Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard size == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            guard info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }

            // Local port is stored in network byte order.
            let raw = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))
            if wanted.contains(port) { found.append(port) }
        }
        return found
    }
}
