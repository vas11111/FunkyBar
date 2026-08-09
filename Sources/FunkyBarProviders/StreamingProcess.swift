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
    private var stopped = false
    private var restartDelay: Double = 0.5

    public init(command: String, onLine: @escaping @MainActor (String) -> Void) {
        self.command = command
        self.onLine = onLine
    }

    /// Spawns immediately, then reads in the background.
    ///
    /// The spawn is deliberately synchronous. Doing it on a background queue
    /// left a window where `stop()` ran before `pid` was recorded, found
    /// nothing to kill, and returned; if the process then exited, the child
    /// outlived it with ppid 1. Short-lived invocations such as `--dump` hit
    /// that window every time.
    public func start() {
        lock.lock()
        stopped = false
        lock.unlock()
        spawn()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let child = pid
        pid = 0
        lock.unlock()

        // Signal only. The read loop owns the descriptor and closes it once
        // the kill drops the write end and `read` returns EOF. Closing it here
        // as well would be a double close, and fd numbers get reused, so the
        // second close can land on an unrelated live descriptor.
        terminate(child)
    }

    /// Signals the whole process group.
    ///
    /// `POSIX_SPAWN_SETSID` makes the child a session and process-group
    /// leader, so `-pid` reaches anything it forked as well.
    private func terminate(_ child: pid_t) {
        guard child > 0 else { return }
        kill(-child, SIGTERM)
        kill(child, SIGTERM)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid > 0
    }

    private func spawn() {
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
        // `exec` so the shell replaces itself: one process to signal and reap,
        // with no grandchild that can outlive it.
        let status = withCStringArray(["/bin/sh", "-c", "exec \(command)"]) { argv in
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
        let shouldStop = stopped
        if !shouldStop { pid = child }
        lock.unlock()

        if shouldStop {
            // Told to stop mid-spawn. Reap here, or it becomes a zombie that
            // is never waited on and the pid is held for the process lifetime.
            terminate(child)
            close(fds[0])
            var ignored: Int32 = 0
            waitpid(child, &ignored, 0)
            return
        }

        let readFD = fds[0]
        queue.async { [weak self] in
            guard let self else {
                close(readFD)
                var ignored: Int32 = 0
                waitpid(child, &ignored, 0)
                return
            }
            self.readLines(from: readFD)

            var exitStatus: Int32 = 0
            waitpid(child, &exitStatus, 0)

            self.lock.lock()
            if self.pid == child { self.pid = 0 }
            self.lock.unlock()

            self.scheduleRestart()
        }
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
            self.spawn()
        }
    }
}

/// Watches a file and reports every change.
///
/// Watches the *containing directory*, not the file. Apps that write state
/// atomically (temp file, delete, rename) destroy
/// the inode on every write, so a watch bound to the file itself dies after
/// the first change and any recovery races the gap where the file does not
/// exist. A directory watch has no such gap.
public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "funkybar.filewatch", qos: .utility)

    // All mutable state behind one lock. `watch()` runs on the background
    // queue via the retry path while `stop()` is called from the main actor.
    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false

    public init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    public func start() {
        lock.lock()
        stopped = false
        lock.unlock()
        watch()
    }

    private func watch() {
        lock.lock()
        let halted = stopped
        lock.unlock()
        // Without this the retry path outlives stop(), installing a live
        // source and a fresh descriptor on a watcher already torn down.
        guard !halted else { return }

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

        lock.lock()
        if stopped {
            lock.unlock()
            source.cancel()
            return
        }
        self.source = source
        lock.unlock()

        source.resume()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let live = source
        source = nil
        lock.unlock()
        live?.cancel()
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
