import Darwin
import Foundation

/// A long-lived child process whose stdout is read line by line.
///
/// Distinct from `ProcessRunner`, which runs a command to completion. Some
/// sources are event streams rather than questions: `aerospace subscribe`
/// holds a socket open and pushes a JSON line per event, which turns workspace
/// tracking from a poll into a notification.
///
/// Restarts with backoff if the child dies, so quitting and relaunching the
/// window manager does not permanently deafen the bar.
public final class StreamingProcess: @unchecked Sendable {

    private let command: String
    private let onLine: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "funkybar.stream", qos: .utility)

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var readFD: Int32 = -1
    private var stopped = false
    private var restartDelay: Double = 0.5

    public init(command: String, onLine: @escaping @MainActor (String) -> Void) {
        self.command = command
        self.onLine = onLine
    }

    public func start() {
        lock.lock()
        stopped = false
        lock.unlock()
        queue.async { [weak self] in self?.spawnAndRead() }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let child = pid
        let fd = readFD
        pid = 0
        readFD = -1
        lock.unlock()

        // Signal the process GROUP, not just the shell. `sh -c "aerospace
        // subscribe"` forks the real command as a grandchild, so SIGTERM to sh
        // alone leaves it running with ppid 1. POSIX_SPAWN_SETSID makes the
        // child a group leader, so pgid == pid and -pid reaches all of it.
        if child > 0 {
            kill(-child, SIGTERM)
            kill(child, SIGTERM)
        }
        if fd >= 0 { close(fd) }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid > 0
    }

    private func spawnAndRead() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return scheduleRestart() }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Same session rule as ProcessRunner: a child in session 0 breaks
        // waitpid for anything it spawns (#807).
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        var child: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let status = withCStringArray(["/bin/sh", "-c", command]) { argv in
            withCStringArray(environment) { envp in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        close(fds[1])

        guard status == 0 else {
            close(fds[0])
            return scheduleRestart()
        }

        lock.lock()
        pid = child
        readFD = fds[0]
        let shouldStop = stopped
        lock.unlock()

        if shouldStop {
            kill(-child, SIGTERM)
            kill(child, SIGTERM)
            close(fds[0])
            return
        }

        readLines(from: fds[0])

        var exitStatus: Int32 = 0
        waitpid(child, &exitStatus, 0)

        lock.lock()
        pid = 0
        readFD = -1
        lock.unlock()

        scheduleRestart()
    }

    private func readLines(from fd: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0 ..< count])

            // A stream can deliver partial lines, so only dispatch complete ones.
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)

                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }

                // A live stream means the source is healthy; reset backoff.
                lock.lock()
                restartDelay = 0.5
                lock.unlock()

                let handler = onLine
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(line) } }
            }
        }
        close(fd)
    }

    private func scheduleRestart() {
        lock.lock()
        let shouldStop = stopped
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        lock.unlock()

        guard !shouldStop else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let halted = self.stopped
            self.lock.unlock()
            guard !halted else { return }
            self.spawnAndRead()
        }
    }
}

/// Watches a file and reports every change.
///
/// Watches the *containing directory*, not the file. Apps that write state
/// atomically (temp file, delete, rename, which is what StatusApp.app does) destroy
/// the inode on every write, so a watch bound to the file itself dies after
/// the first change and any recovery races the gap where the file does not
/// exist. A directory watch has no such gap.
public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "funkybar.filewatch", qos: .utility)

    public init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    public func start() {
        watch()
    }

    private func watch() {
        let directory = (path as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.watch() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .link, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let handler = self.onChange
            // A directory event says something in it changed, not what. The
            // reader re-reads and compares, so a spurious wake is harmless.
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }
}

private func withCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
