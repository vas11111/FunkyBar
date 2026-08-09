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
///   means a wedged command cannot fork-bomb the bar.
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
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    /// Runs `command` through `/bin/sh -c` off the main thread.
    public func run(
        _ command: String,
        environment: [String: String] = [:],
        completion: @escaping @Sendable (Swift.Result<Result, Failure>) -> Void
    ) {
        Self.queue.async {
            guard Self.semaphore.wait(timeout: .now() + 2) == .success else {
                completion(.failure(.busy))
                return
            }
            defer { Self.semaphore.signal() }
            completion(self.runSynchronously(command, environment: environment))
        }
    }

    public func runSynchronously(
        _ command: String,
        environment: [String: String] = [:]
    ) -> Swift.Result<Result, Failure> {
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

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        let envStrings = merged.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let status = withCStrings(["/bin/sh", "-c", command]) { argv in
            withCStrings(envStrings) { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }

        close(outPipe[1])
        close(errPipe[1])

        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return .failure(.spawnFailed(errno: status))
        }

        // Drain both pipes concurrently. Reading them in sequence deadlocks as
        // soon as the child fills the one we are not reading, which is the
        // classic trap with two pipes.
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        let lock = NSLock()

        for (fd, isStdout) in [(outPipe[0], true), (errPipe[0], false)] {
            group.enter()
            Self.queue.async {
                let data = Self.readAll(fd, limit: self.outputLimit)
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                close(fd)
                group.leave()
            }
        }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // Group-wide, for the same reason as StreamingProcess: the shell
            // may have forked the real work as a grandchild.
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            if group.wait(timeout: .now() + 1) == .timedOut {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                _ = group.wait(timeout: .now() + 1)
            }
        }

        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)

        return .success(
            Result(
                status: timedOut ? -1 : (exitStatus >> 8) & 0xFF,
                standardOutput: String(decoding: outData, as: UTF8.self),
                standardError: String(decoding: errData, as: UTF8.self),
                timedOut: timedOut
            )
        )
    }

    private static func readAll(_ fd: Int32, limit: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return data
    }
}

/// Bridges `[String]` to the NULL-terminated `char *const *` spawn wants.
private func withCStrings<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
