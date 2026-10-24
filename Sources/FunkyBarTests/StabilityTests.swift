import AppKit
import Foundation
import TestKit
import FunkyBarCore
import FunkyBarProviders
import FunkyBarRender

@MainActor
private final class TestClock {
    var time: Double
    var fires = 0
    var lines: [String] = []
    var updates: [ProviderUpdate] = []
    init(_ time: Double) { self.time = time }
}

@MainActor
private func spinUntil(timeout: Double = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

let stabilitySuites: [Suite] = [
    Suite("AeroSpace query regressions") { s in
        s.test("literal executable paths, polling focus and empty workspace lists are handled") { t in
            try withTemporaryDirectory { directory in
                let executable = directory.appendingPathComponent("aero; literal")
                let workspaceFile = directory.appendingPathComponent("workspaces")
                let focusFile = directory.appendingPathComponent("focus")
                let script = """
                #!/bin/sh
                if [ "$1" = subscribe ]; then exec /bin/sleep 30; fi
                if [ "$2" = --focused ]; then
                  /bin/cat \(focusFile.path.shellQuoted)
                else
                  /bin/cat \(workspaceFile.path.shellQuoted)
                fi
                """
                try script.write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                try "---\ndev.ops\n".write(to: workspaceFile, atomically: true, encoding: .utf8)
                try "---\n".write(to: focusFile, atomically: true, encoding: .utf8)
                let options = try TOMLParser.parse("binary = '\(executable.path)'")
                let result = try MainActor.assumeIsolated {
                    let counter = TestClock(0)
                    let provider = AeroSpaceProvider(.init(itemID: "spaces", options: options, interval: nil))
                    provider.start { counter.updates.append($0) }
                    defer { provider.stop() }
                    _ = provider.refresh()
                    let first = spinUntil { counter.updates.last?.values["focused"] == "---" }
                    try "dev.ops\n".write(to: focusFile, atomically: true, encoding: .utf8)
                    _ = provider.refresh()
                    let second = spinUntil { counter.updates.last?.values["focused"] == "dev.ops" }
                    try "".write(to: workspaceFile, atomically: true, encoding: .utf8)
                    _ = provider.refresh()
                    let empty = spinUntil { counter.updates.last?.expansion == [] }
                    return [first, second, empty]
                }
                t.expectEqual(result, [true, true, true])
            }
        }
    },

    Suite("Streaming process regressions") { s in
        s.test("direct stream arguments are not interpreted by a shell") { t in
            let lines = MainActor.assumeIsolated {
                let counter = TestClock(0)
                let argument = "$(printf PWNED); 'literal'"
                let stream = StreamingProcess(executable: "/usr/bin/printf", arguments: ["%s\n", argument]) {
                    counter.lines.append($0)
                }
                stream.start()
                defer { stream.stop() }
                _ = spinUntil { !counter.lines.isEmpty }
                return counter.lines
            }
            t.expectEqual(lines, ["$(printf PWNED); 'literal'"])
        }

        s.test("oversized stream lines are dropped and the next line survives") { t in
            let lines = MainActor.assumeIsolated {
                let counter = TestClock(0)
                let stream = StreamingProcess(executable: "/bin/sh", arguments: ["-c",
                    "/usr/bin/head -c 70000 /dev/zero; printf '\\nhealthy\\n'; sleep 2"
                ]) { counter.lines.append($0) }
                stream.start()
                defer { stream.stop() }
                _ = spinUntil { !counter.lines.isEmpty }
                return counter.lines
            }
            t.expectEqual(lines, ["healthy"])
        }

        s.test("stop reaps a stream that ignores TERM") { t in
            let stopped = MainActor.assumeIsolated {
                let counter = TestClock(0)
                let stream = StreamingProcess(executable: "/bin/sh", arguments: ["-c",
                    "trap '' TERM; printf '%s\\n' $$; while :; do sleep 1; done"
                ]) { counter.lines.append($0) }
                stream.start()
                _ = spinUntil { !counter.lines.isEmpty }
                guard let line = counter.lines.first, let pid = Int32(line) else {
                    stream.stop()
                    return false
                }
                stream.stop()
                return spinUntil { Darwin.kill(pid, 0) != 0 && errno == ESRCH }
            }
            t.expect(stopped, "a stopped stream survived or was not reaped")
        }
    },

    Suite("File watcher regressions") { s in
        s.test("in-place writes are reported without replacing the file") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("state")
                try Data("initial".utf8).write(to: file)
                let changed = try MainActor.assumeIsolated {
                    let counter = TestClock(0)
                    let watcher = FileWatcher(path: file.path) { counter.fires += 1 }
                    watcher.start()
                    defer { watcher.stop() }
                    let handle = try FileHandle(forWritingTo: file)
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: Data("updated".utf8))
                    try handle.close()
                    return spinUntil { counter.fires > 0 }
                }
                t.expect(changed)
            }
        }

        s.test("atomic replacements, deletion and recreation keep reporting") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("missing/state")
                let counts = try MainActor.assumeIsolated {
                    let counter = TestClock(0)
                    let watcher = FileWatcher(path: file.path) { counter.fires += 1 }
                    watcher.start()
                    defer { watcher.stop() }
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "first".write(to: file, atomically: true, encoding: .utf8)
                    let created = spinUntil { counter.fires >= 1 }
                    try "second".write(to: file, atomically: true, encoding: .utf8)
                    let replaced = spinUntil { counter.fires >= 2 }
                    try FileManager.default.removeItem(at: file)
                    let deleted = spinUntil { counter.fires >= 3 }
                    try "third".write(to: file, atomically: true, encoding: .utf8)
                    let recreated = spinUntil { counter.fires >= 4 }
                    return [created, replaced, deleted, recreated]
                }
                t.expectEqual(counts, [true, true, true, true])
            }
        }

        s.test("symlink target writes and retargeting are both observed") { t in
            try withTemporaryDirectory { directory in
                let first = directory.appendingPathComponent("a/state")
                let second = directory.appendingPathComponent("b/state")
                let link = directory.appendingPathComponent("state-link")
                for file in [first, second] {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "initial".write(to: file, atomically: true, encoding: .utf8)
                }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
                let counts = try MainActor.assumeIsolated {
                    let counter = TestClock(0)
                    let watcher = FileWatcher(path: link.path) { counter.fires += 1 }
                    watcher.start()
                    defer { watcher.stop() }
                    try "changed".write(to: first, atomically: true, encoding: .utf8)
                    let targetWrite = spinUntil { counter.fires >= 1 }
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
                    let retargeted = spinUntil { counter.fires >= 2 }
                    try "another".write(to: second, atomically: true, encoding: .utf8)
                    let newTargetWrite = spinUntil { counter.fires >= 3 }
                    return [targetWrite, retargeted, newTargetWrite]
                }
                t.expectEqual(counts, [true, true, true])
            }
        }

        s.test("sibling writes and events after stop do not trigger reloads") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("state")
                try "initial".write(to: file, atomically: true, encoding: .utf8)
                let count = try MainActor.assumeIsolated {
                    let counter = TestClock(0)
                    let watcher = FileWatcher(path: file.path) { counter.fires += 1 }
                    watcher.start()
                    watcher.start()
                    try "unrelated".write(to: directory.appendingPathComponent("sibling"), atomically: true, encoding: .utf8)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                    watcher.stop()
                    try "stopped".write(to: file, atomically: true, encoding: .utf8)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                    return counter.fires
                }
                t.expectEqual(count, 0)
            }
        }
    },

    Suite("Push snapshot regressions") { s in
        s.test("empty delimited fields keep their positions and shortened records clear old values") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("state")
                let options = try TOMLParser.parse("seed_file = '\(file.path)'\nseed_keys = ['a', 'b', 'c']\nseed_separator = ','")
                let snapshots = try MainActor.assumeIsolated {
                    let provider = PushProvider(.init(itemID: "coins", options: options, interval: nil))
                    try "1,,3".write(to: file, atomically: true, encoding: .utf8)
                    let first = provider.refresh()
                    try "4".write(to: file, atomically: true, encoding: .utf8)
                    return [first, provider.refresh()]
                }
                t.expectEqual(snapshots[0]?.perItem["coins.a"]?["value"], "1")
                t.expectNil(snapshots[0]?.perItem["coins.b"]?["value"])
                t.expectEqual(snapshots[0]?.perItem["coins.c"]?["value"], "3")
                t.expectEqual(snapshots[1]?.perItem["coins.a"]?["value"], "4")
                t.expectNil(snapshots[1]?.perItem["coins.c"])
            }
        }

        s.test("clearing a scalar state file clears its displayed value") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("state")
                let options = try TOMLParser.parse("seed_file = '\(file.path)'")
                let snapshots = try MainActor.assumeIsolated {
                    let provider = PushProvider(.init(itemID: "status", options: options, interval: nil))
                    try "ON".write(to: file, atomically: true, encoding: .utf8)
                    let first = provider.refresh()
                    try "".write(to: file, atomically: true, encoding: .utf8)
                    return [first, provider.refresh()]
                }
                t.expectEqual(snapshots[0]?.values["value"], "ON")
                t.expectEqual(snapshots[1]?.values["value"], "")
            }
        }
    },

    Suite("Execution boundary regressions") { s in
        s.test("direct arguments preserve shell metacharacters literally") { t in
            let argument = "$(printf PWNED); `printf PWNED` 'quoted'\nnext"
            let result = ProcessRunner().runSynchronously(executable: "/usr/bin/printf", arguments: ["%s", argument])
            guard case .success(let output) = result else { return t.fail("spawn failed") }
            t.expectEqual(output.standardOutput, argument)
            t.expectEqual(output.succeeded, true)
        }

        s.test("an executable name cannot inject another command") { t in
            let result = ProcessRunner().runSynchronously(executable: "/bin/echo; printf PWNED", arguments: [])
            guard case .failure(.spawnFailed) = result else { return t.fail("an invalid executable was accepted") }
        }

        s.test("embedded NUL bytes are rejected before spawning") { t in
            let result = ProcessRunner().runSynchronously("printf unsafe\u{0}suffix")
            guard case .failure(.spawnFailed(let error)) = result else { return t.fail("a truncated command was accepted") }
            t.expectEqual(error, EINVAL)
        }

        s.test("trusted configs support symlinks and reject unsafe permissions") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("config.toml")
                let link = directory.appendingPathComponent("link.toml")
                try "[bar]\nheight = 36\n".write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
                t.expectEqual(try ConfigFile.read(link.path), "[bar]\nheight = 36\n")
                try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
                try t.expectThrows { try ConfigFile.read(file.path) }
            }
        }

        s.test("a FIFO config is rejected without blocking") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("fifo")
                t.expectEqual(mkfifo(file.path, 0o600), 0)
                try t.expectThrows { try ConfigFile.read(file.path) }
            }
        }

        s.test("oversized and invalid UTF-8 configs are rejected") { t in
            try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("config.toml")
                try Data(repeating: 65, count: 1024 * 1024 + 1).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try t.expectThrows { try ConfigFile.read(file.path) }
                try Data([0xFF]).write(to: file)
                try t.expectThrows { try ConfigFile.read(file.path) }
            }
        }
    },

    Suite("Popup placement regressions") { s in
        s.test("bottom-bar popups open above their anchor") { t in
            let anchor = CGRect(x: 200, y: 0, width: 80, height: 36)
            let frame = PopupPlacement.frame(size: CGSize(width: 200, height: 300), anchor: anchor,
                                             screen: CGRect(x: 0, y: 0, width: 1000, height: 800), edge: .bottom)
            t.expect(frame.minY > anchor.maxY)
        }

        s.test("oversized popups stay inside a secondary display") { t in
            let screen = CGRect(x: -1200, y: 500, width: 1200, height: 800)
            let frame = PopupPlacement.frame(size: CGSize(width: 2000, height: 2000),
                                             anchor: CGRect(x: -50, y: 1260, width: 50, height: 36),
                                             screen: screen, edge: .top)
            t.expect(screen.contains(frame))
            t.expect(frame.width < screen.width && frame.height < screen.height)
        }

        s.test("right alignment follows the right edge of the item") { t in
            let anchor = CGRect(x: 500, y: 760, width: 80, height: 36)
            let frame = PopupPlacement.frame(size: CGSize(width: 200, height: 100), anchor: anchor,
                                             screen: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                             edge: .top, alignment: .right)
            t.expectEqual(frame.maxX, anchor.maxX)
        }
    },

    Suite("Repeated interaction regressions") { s in
        s.test("dynamic clones inherit actions and provider fields for clicks") { t in
            let source = """
            [[item]]
            id = "spaces"
            repeat = "workspace"
            on_click = { workspace = "{workspace}" }
            """
            let config = ConfigDecoder.decode(try TOMLParser.parse(source)).config
            let clone = try t.require(config.item(withID: "spaces.dev.ops"))
            let fields = ConfigResolver.values(for: clone, inputs: .init(values: ["spaces": ["shared":"yes"]]))
            t.expectEqual(clone.repeatValue, "dev.ops")
            t.expectEqual(fields["shared"], "yes")
            guard case .workspace(let template) = clone.actions[.left] else { return t.fail("missing clone action") }
            t.expectEqual(template.render(fields), "dev.ops")
        }
    },

    Suite("Process lifecycle regressions") { s in
        s.test("the deadline still applies after both output pipes close") { t in
            let started = Date()
            let result = ProcessRunner(timeout: 0.1).runSynchronously("exec >/dev/null 2>&1; sleep 1.5")
            guard case .success(let output) = result else { return t.fail("spawn failed") }
            t.expect(output.timedOut)
            t.expect(Date().timeIntervalSince(started) < 1, "closed pipes bypassed the deadline")
        }

        s.test("signal termination is a failure") { t in
            let result = ProcessRunner().runSynchronously("kill -TERM $$")
            guard case .success(let output) = result else { return t.fail("spawn failed") }
            t.expectEqual(output.status, 128 + SIGTERM)
            t.expectEqual(output.succeeded, false)
        }

        s.test("output is capped exactly while excess bytes are drained") { t in
            let result = ProcessRunner(outputLimit: 17).runSynchronously("/usr/bin/head -c 65536 /dev/zero")
            guard case .success(let output) = result else { return t.fail("spawn failed") }
            t.expectEqual(output.standardOutput.utf8.count, 17)
            t.expectEqual(output.status, 0, "the output cap must not terminate the writer")
        }

        s.test("zero output capacity still lets a command finish") { t in
            let result = ProcessRunner(outputLimit: 0).runSynchronously("/usr/bin/head -c 65536 /dev/zero")
            guard case .success(let output) = result else { return t.fail("spawn failed") }
            t.expectEqual(output.standardOutput, "")
            t.expectEqual(output.succeeded, true)
        }

        s.test("a child retaining the pipes cannot outlive the deadline") { t in
            let started = Date()
            let result = ProcessRunner(timeout: 0.1).runSynchronously("sleep 2 & exit 0")
            guard case .success(let output) = result else { return t.fail("spawn failed") }
            t.expect(output.timedOut)
            t.expect(Date().timeIntervalSince(started) < 1)
        }
    },

    Suite("Timer scheduling regressions") { s in
        s.test("wake refreshes immediately and schedules the next aligned boundary") { t in
            let fires = MainActor.assumeIsolated {
                let clock = TestClock(61)
                let wheel = TimerWheel(now: { clock.time })
                defer { wheel.removeAll() }
                wheel.register(id: "clock", interval: 60) { clock.fires += 1 }
                wheel.suspend()
                clock.time = 125
                wheel.resume()
                let immediate = clock.fires
                wheel.tickNow()
                let sameTurn = clock.fires
                clock.time = 180
                wheel.tickNow()
                return [immediate, sameTurn, clock.fires]
            }
            t.expectEqual(fires, [1, 1, 2])
        }

        s.test("minute updates align to the clock and do not drift after late delivery") { t in
            let counts = MainActor.assumeIsolated {
                let clock = TestClock(61)
                let wheel = TimerWheel(now: { clock.time })
                defer { wheel.removeAll() }
                wheel.register(id: "clock", interval: 60) { clock.fires += 1 }
                wheel.tickNow()
                let initial = clock.fires
                clock.time = 120.2
                wheel.tickNow()
                let late = clock.fires
                clock.time = 180
                wheel.tickNow()
                return [initial, late, clock.fires]
            }
            t.expectEqual(counts, [0, 1, 2], "late delivery must not move the next minute")
        }

        s.test("timer callbacks may remove their own entries") { t in
            let count = MainActor.assumeIsolated {
                let clock = TestClock(1)
                let wheel = TimerWheel(now: { clock.time })
                defer { wheel.removeAll() }
                wheel.register(id: "once", interval: 1) { wheel.removeAll() }
                clock.time = 2
                wheel.tickNow()
                return wheel.registeredCount
            }
            t.expectEqual(count, 0)
        }

        s.test("a backwards clock adjustment refreshes providers") { t in
            let fires = MainActor.assumeIsolated {
                let clock = TestClock(120)
                let wheel = TimerWheel(now: { clock.time })
                defer { wheel.removeAll() }
                wheel.register(id: "clock", interval: 60) { clock.fires += 1 }
                clock.time = 180
                wheel.tickNow()
                clock.time = 90
                wheel.tickNow()
                return clock.fires
            }
            t.expectEqual(fires, 2)
        }

        s.test("non-finite and enormous intervals cannot trap integer conversion") { t in
            for interval in [Double.infinity, .nan, -.infinity, 1e100] {
                let tick = TimerWheel.tickInterval(for: [interval])
                t.expect(tick.isFinite && tick >= 1)
            }
        }
    },

    Suite("Numeric config regressions") { s in
        s.test("recursive table and array tokens fail within a bounded expansion") { t in
            let sources = [
                "[theme]\nloop = { next = '$loop' }\n[bar]\ncolor = '$loop'",
                "[theme]\nloop = ['$loop','$loop','$loop','$loop','$loop','$loop','$loop','$loop','$loop','$loop']",
            ]
            for source in sources {
                let outcome = ConfigDecoder.decode(try TOMLParser.parse(source))
                t.expectEqual(outcome.isUsable, false)
                t.expect(outcome.diagnostics.errors.count < 10, "one expansion must not flood diagnostics")
            }
        }

        s.test("non-finite geometry is rejected before reaching AppKit") { t in
            for value in ["inf", "nan", "-inf"] {
                let config = "[bar]\nheight = \(value)\noffset = { x = \(value) }"
                let outcome = ConfigDecoder.decode(try TOMLParser.parse(config))
                t.expectEqual(outcome.isUsable, false)
            }
        }

        s.test("negative and overflowing durations are rejected consistently") { t in
            for value in ["-1", "inf", "nan", "1e100", "\"-1s\"", "\"1e308h\""] {
                let config = "[[item]]\nid = 'clock'\nprovider = 'clock'\ninterval = \(value)"
                let outcome = ConfigDecoder.decode(try TOMLParser.parse(config))
                t.expectEqual(outcome.isUsable, false, value)
            }
        }

        s.test("font shorthand rejects non-positive and non-finite sizes") { t in
            for size in ["0", "-5", "inf", "nan"] {
                t.expectNil(FontSpec.parse("Helvetica:Regular:\(size)"))
            }
        }

        s.test("valid whole numbers near the Int boundary still decode") { t in
            let sink = DiagnosticSink()
            let table = try TOMLParser.parse("value = 9.21e18")
            let reader = ConfigReader(table: table, path: "", sink: sink)
            t.expectEqual(reader.int("value"), 9_210_000_000_000_000_000)
            t.expectEqual(sink.hasErrors, false)
        }
    },
]
