import Darwin
import Foundation
import TestKit
import FunkyBarCore
import FunkyBarProviders

// MARK: - Timer wheel

let timerWheelTests = Suite("Timer wheel") { s in

    s.test("one interval ticks at that interval") { t in
        t.expectEqual(TimerWheel.tickInterval(for: [5]), 5)
    }

    s.test("several intervals share their greatest common divisor") { t in
        // 5s and 60s providers share one 5s timer rather than owning two.
        t.expectEqual(TimerWheel.tickInterval(for: [5, 60]), 5)
        t.expectEqual(TimerWheel.tickInterval(for: [10, 15]), 5)
        t.expectEqual(TimerWheel.tickInterval(for: [60, 300]), 60)
        t.expectEqual(TimerWheel.tickInterval(for: [30, 60, 120]), 30)
    }

    s.test("coprime intervals fall back to the finest common tick") { t in
        t.expectEqual(TimerWheel.tickInterval(for: [7, 11]), 1)
    }

    s.test("never ticks faster than once a second") { t in
        // Sub-second polling has no place on a status bar.
        t.expectEqual(TimerWheel.tickInterval(for: [0.1]), 1)
        t.expectEqual(TimerWheel.tickInterval(for: [0.25, 0.5]), 1)
    }

    s.test("an empty wheel has no timer at all") { t in
        t.expectEqual(TimerWheel.tickInterval(for: []), 1)
    }
}

// MARK: - Ports

let portsProviderTests = Suite("Ports provider") { s in

    /// Opens a listening socket on an ephemeral port and returns both.
    @Sendable func withListeningSocket(_ body: (UInt16) -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // let the kernel pick
        address.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { return }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return }

        body(UInt16(bigEndian: actual.sin_port))
    }

    s.test("finds a real listening socket without shelling out") { t in
        withListeningSocket { port in
            let scan = PortsProvider.scan(ports: [port], processes: [])
            t.expect(
                scan.listening.contains { $0.port == port },
                "expected to find port \(port) among \(scan.listening.map(\.port).sorted())"
            )
        }
    }

    s.test("attributes the socket to this process") { t in
        withListeningSocket { port in
            let scan = PortsProvider.scan(ports: [port], processes: [])
            let listener = scan.listening.first { $0.port == port }
            t.expectEqual(listener?.pid, ProcessInfo.processInfo.processIdentifier)
        }
    }

    s.test("does not report a port nobody is listening on") { t in
        // 1 is reserved and never bound by a normal process.
        t.expectEqual(PortsProvider.scan(ports: [1], processes: []).listening.isEmpty, true)
    }

    s.test("finds a watched process by name") { t in
        let mine = ProcessInfo.processInfo.processName
        t.expect(
            PortsProvider.scan(ports: [], processes: [mine]).runningProcesses.contains(mine),
            "expected to find this test process by name"
        )
    }

    s.test("beats lsof by a wide margin on a realistic port list") { t in
        let ports: Set<UInt16> = [3000, 3001, 5173, 8080, 8081, 8443, 9000, 9090]
        let processes: Set<String> = ["node", "ruby"]

        // Warm the page cache so the first call does not carry setup cost.
        _ = PortsProvider.scan(ports: ports, processes: processes)

        let iterations = 20
        let started = Date()
        for _ in 0 ..< iterations {
            _ = PortsProvider.scan(ports: ports, processes: processes)
        }
        let perScan = Date().timeIntervalSince(started) / Double(iterations) * 1000

        // A shell equivalent measures 94ms per invocation. Anything near that
        // would mean the in-process scan bought nothing.
        t.expect(perScan < 25, "scan took \(String(format: "%.1f", perScan))ms; lsof takes ~94ms")
        print("       ports scan: \(String(format: "%.2f", perScan))ms/call (lsof: ~94ms)")
    }
}

// MARK: - Process runner

let processRunnerTests = Suite("Process runner") { s in

    let runner = ProcessRunner(timeout: 5)

    s.test("captures stdout") { t in
        guard case .success(let result) = runner.runSynchronously("echo hello") else {
            t.fail("spawn failed")
            return
        }
        t.expectEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        t.expectEqual(result.status, 0)
        t.expectEqual(result.succeeded, true)
    }

    s.test("captures stderr separately") { t in
        guard case .success(let result) = runner.runSynchronously("echo oops >&2") else {
            t.fail("spawn failed")
            return
        }
        t.expectEqual(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
        t.expectEqual(result.standardOutput, "")
    }

    s.test("reports a non-zero exit status") { t in
        guard case .success(let result) = runner.runSynchronously("exit 3") else {
            t.fail("spawn failed")
            return
        }
        t.expectEqual(result.status, 3)
        t.expectEqual(result.succeeded, false)
    }

    s.test("the child gets its own session, which is the #807 fix") { t in
        // Upstream uses vfork + execvp with no setsid, leaving children in
        // session 0 with no controlling terminal. On macOS 26 that breaks
        // waitpid in grandchildren, which is why `brew outdated` crashes
        // inside a sketchybar plugin.
        //
        // `ps -o sess=` reports 0 for everything on this platform, so it
        // cannot distinguish the two cases. Session leadership can: setsid
        // makes the child both a session and a process-group leader, so its
        // pid equals its pgid, and its pgid differs from ours.
        guard case .success(let result) = runner.runSynchronously("ps -o pid=,pgid= -p $$") else {
            t.fail("spawn failed")
            return
        }
        let fields = result.standardOutput
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        guard fields.count == 2 else {
            t.fail("could not read pid/pgid from \"\(result.standardOutput)\"")
            return
        }
        let (pid, pgid) = (fields[0], fields[1])
        t.expectEqual(pid, pgid, "a session leader is its own process-group leader")
        t.expect(
            pgid != Int(getpgid(0)),
            "child pgid \(pgid) matches ours; POSIX_SPAWN_SETSID did not take effect"
        )
    }

    s.test("a grandchild can waitpid, which session 0 would break") { t in
        // The concrete shape of #807: a child that itself forks and waits.
        guard case .success(let result) = runner.runSynchronously(
            "out=$(getconf _NPROCESSORS_ONLN); echo \"status=$? value=$out\""
        ) else {
            t.fail("spawn failed")
            return
        }
        t.expectContains(result.standardOutput, "status=0")
    }

    s.test("kills a command that overruns its deadline") { t in
        let impatient = ProcessRunner(timeout: 0.5)
        let started = Date()
        guard case .success(let result) = impatient.runSynchronously("sleep 30") else {
            t.fail("spawn failed")
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        t.expectEqual(result.timedOut, true)
        t.expect(elapsed < 5, "took \(elapsed)s; the deadline should have fired at 0.5s")
    }

    s.test("large output does not deadlock on a full pipe") { t in
        // Reading the two pipes in sequence deadlocks as soon as the child
        // fills the one not being read. This is the trap INTEGRATION.md warns
        // about, here at a size that certainly exceeds the pipe buffer.
        guard case .success(let result) = runner.runSynchronously(
            "for i in $(seq 1 5000); do echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; done"
        ) else {
            t.fail("spawn failed")
            return
        }
        t.expectEqual(result.timedOut, false)
        t.expect(result.standardOutput.count > 200_000, "expected large output, got \(result.standardOutput.count) bytes")
    }

    s.test("environment overrides reach the child") { t in
        guard case .success(let result) = runner.runSynchronously(
            "echo $FUNKYBAR_TEST", environment: ["FUNKYBAR_TEST": "wired"]
        ) else {
            t.fail("spawn failed")
            return
        }
        t.expectEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "wired")
    }
}

let providerSuites: [Suite] = [
    popupRowTests,
    timerWheelTests,
    portsProviderTests,
    processRunnerTests,
]

// MARK: - Popup rows

let popupRowTests = Suite("Popup rows") { s in

    @Sendable func withListener(_ body: (UInt16) -> Void) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { return }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        body(UInt16(bigEndian: actual.sin_port))
    }

    s.test("a listening port becomes a row with a kill action") { t in
        withListener { port in
            var options = TOMLTable()
            options.insert(TOMLNode(.array([TOMLNode(.integer(Int(port)), at: .unknown)]), at: .unknown),
                           for: "ports")
            let context = ProviderContext(itemID: "ports", options: options, interval: nil)

            let update = MainActor.assumeIsolated { PortsProvider(context).refresh() }
            guard let rows = update?.rows else {
                t.fail("no rows produced")
                return
            }
            guard let row = rows.first(where: { $0.icon == String(port) }) else {
                t.fail("no row for port \(port); got \(rows.map(\.icon))")
                return
            }
            // The scan already knows the pid, so the kill needs no second
            // lookup the way ports_kill.sh did.
            let action = try? t.require(row.action)
            t.expectContains(action ?? "", "kill:pid:")
            t.expectContains(action ?? "", String(ProcessInfo.processInfo.processIdentifier))
        }
    }

    s.test("a stopped watched process gets a row but no kill action") { t in
        var options = TOMLTable()
        options.insert(TOMLNode(.array([TOMLNode(.string("definitely-not-running-xyz"), at: .unknown)]), at: .unknown),
                       for: "watch")
        let context = ProviderContext(itemID: "ports", options: options, interval: nil)

        let update = MainActor.assumeIsolated { PortsProvider(context).refresh() }
        let rows = try t.require(update?.rows)
        let row = try t.require(rows.first { $0.icon == "definitely-not-running-xyz" })
        t.expectEqual(row.label, "stopped")
        t.expectNil(row.action, "nothing to kill, so nothing should be clickable")
    }

    s.test("an empty scan still produces a row rather than an empty popup") { t in
        let context = ProviderContext(itemID: "ports", options: TOMLTable(), interval: nil)
        let update = MainActor.assumeIsolated { PortsProvider(context).refresh() }
        let rows = try t.require(update?.rows)
        t.expectEqual(rows.count, 1)
        t.expectContains(rows[0].label, "nothing listening")
    }
}
