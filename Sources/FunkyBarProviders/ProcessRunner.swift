import Darwin
import Foundation

/// Runs short-lived commands for the providers that still need a subprocess.
///
/// Two things upstream gets wrong and this fixes:
///
/// - **Session.** Upstream uses `vfork()` + `execvp()` with no `setsid()`, so
///   every plugin runs in session 0 with no controlling terminal. On macOS 26
///   that breaks `waitpid()` in grandchildren, which is why `brew outdated`
///   crashes inside a sketchybar plugin (#807). `POSIX_SPAWN_SETSID` gives the
///   child its own session.
/// - **Runaway children.** Upstream sets an `alarm()` and hopes. Here every run
///   has a hard deadline, output is capped, and a global concurrency limit
///   limits how many commands the bar launches at once.
public struct ProcessRunner: Sendable {

    public struct Result: Sendable {
        public let status: Int32
        public let standardOutput: String
        public let standardError: String
        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }
    }

    public enum Failure: Error, Sendable {
        case spawnFailed(errno: Int32)
        case busy
    }

    /// Caps how many commands can be in flight at once across the whole bar.
    private static let semaphore = DispatchSemaphore(value: 4)
    private static let queue = DispatchQueue(
        label: "funkybar.process", qos: .utility, attributes: .concurrent
    )

    public let timeout: Double
    public let outputLimit: Int

    public init(timeout: Double = 5, outputLimit: Int = 1 << 20) {
        self.timeout = timeout.isFinite ? max(0, timeout) : 5
        self.outputLimit = max(0, outputLimit)
    }

    /// Runs `command` through `/bin/sh -c` off the main thread.
    public func run(
        _ command: String,
        environment: [String: String] = [:],
        completion: @escaping @Sendable (Swift.Result<Result, Failure>) -> Void
    ) {
        Self.queue.async {
            completion(self.runSynchronously(command, environment: environment))
        }
    }

    /// Built-in actions pass data as arguments, bypassing shell parsing.
    public func run(
        executable: String,
        arguments: [String],
        completion: @escaping @Sendable (Swift.Result<Result, Failure>) -> Void
    ) {
        Self.queue.async {
            completion(self.runSynchronously(executable: executable, arguments: arguments))
        }
    }

    public func runSynchronously(
        _ command: String,
        environment: [String: String] = [:]
    ) -> Swift.Result<Result, Failure> {
        runSynchronously(executable: "/bin/sh", arguments: ["-c", command], environment: environment)
    }

    public func runSynchronously(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Swift.Result<Result, Failure> {
        var merged = ProcessInfo.processInfo.environment
        merged.merge(environment) { _, new in new }
        let envStrings = merged.map { "\($0.key)=\($0.value)" }
        guard !executable.isEmpty,
              ([executable] + arguments + envStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
            return .failure(.spawnFailed(errno: EINVAL))
        }
        guard Self.semaphore.wait(timeout: .now()) == .success else {
            return .failure(.busy)
        }
        defer { Self.semaphore.signal() }

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { return .failure(.spawnFailed(errno: errno)) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return .failure(.spawnFailed(errno: errno))
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // POSIX_SPAWN_SETSID is the fix for #807. CLOEXEC_DEFAULT keeps our
        // socket and config descriptors out of the child.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        var pid: pid_t = 0
        let status = withCStrings([executable] + arguments) { argv in
            withCStrings(envStrings) { envp in
                posix_spawnp(&pid, executable, &actions, &attributes, argv, envp)
            }
        }

        close(outPipe[1])
        close(errPipe[1])

        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return .failure(.spawnFailed(errno: status))
        }

        // Drain both pipes without blocking, and track the child separately.
        // EOF is not process exit: a command can close its output and keep
        // running. Conversely, a grandchild can retain output after the shell
        // exits. Both cases must remain subject to the same deadline.
        let descriptors = [outPipe[0], errPipe[0]]
        for fd in descriptors {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        var polls = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        defer { for entry in polls where entry.fd >= 0 { close(entry.fd) } }

        var outData = Data()
        var errData = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        var sentKill = false
        var exited = false
        var exitStatus: Int32 = 0

        while true {
            if !exited {
                let waited = waitpid(pid, &exitStatus, WNOHANG)
                if waited == pid { exited = true }
                else if waited < 0, errno != EINTR {
                    exited = true
                    exitStatus = -1
                }
            }
            if exited && polls.allSatisfy({ $0.fd < 0 }) { break }

            let current = ProcessInfo.processInfo.systemUptime
            if !timedOut, current >= deadline {
                timedOut = true
                kill(-pid, SIGTERM)
                if !exited { kill(pid, SIGTERM) }
            }
            if timedOut, !sentKill, current >= deadline + 0.25 {
                sentKill = true
                kill(-pid, SIGKILL)
                if !exited { kill(pid, SIGKILL) }
            }
            // A detached descendant may keep a pipe open even after the
            // process group is gone. Do not wait indefinitely for its EOF.
            if timedOut, current >= deadline + 0.5 {
                if !exited {
                    while waitpid(pid, &exitStatus, 0) < 0, errno == EINTR {}
                }
                break
            }

            let remaining = timedOut ? 0.05 : max(0, min(0.05, deadline - current))
            _ = poll(&polls, nfds_t(polls.count), Int32((remaining * 1000).rounded(.up)))
            for index in polls.indices where polls[index].fd >= 0 && polls[index].revents != 0 {
                // Bound work per turn so continuous output cannot starve the
                // deadline or the other pipe. Excess bytes are still drained,
                // so the output cap never gives a healthy child SIGPIPE.
                for _ in 0 ..< 4 {
                    let count = read(polls[index].fd, &buffer, buffer.count)
                    if count > 0 {
                        if index == 0 {
                            outData.append(contentsOf: buffer.prefix(min(count, outputLimit - outData.count)))
                        } else {
                            errData.append(contentsOf: buffer.prefix(min(count, outputLimit - errData.count)))
                        }
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                            close(polls[index].fd)
                            polls[index].fd = -1
                        }
                        break
                    }
                }
            }
        }

        let signal = exitStatus & 0x7F
        let statusCode = exitStatus == -1 ? -1
            : (signal == 0 ? (exitStatus >> 8) & 0xFF : 128 + signal)

        return .success(
            Result(
                status: timedOut ? -1 : statusCode,
                standardOutput: String(decoding: outData, as: UTF8.self),
                standardError: String(decoding: errData, as: UTF8.self),
                timedOut: timedOut
            )
        )
    }

}

/// Bridges `[String]` to the NULL-terminated `char *const *` spawn wants.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
