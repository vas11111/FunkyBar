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

    private let executable: String
    private let arguments: [String]
    private let onLine: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "funkybar.stream", qos: .utility)

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopped = true
    private var restartDelay: Double = 0.5
    private let pendingLines = DispatchSemaphore(value: 128)

    public init(command: String, onLine: @escaping @MainActor (String) -> Void) {
        self.executable = "/bin/sh"
        self.arguments = ["-c", "exec \(command)"]
        self.onLine = onLine
    }

    public init(executable: String, arguments: [String], onLine: @escaping @MainActor (String) -> Void) {
        self.executable = executable
        self.arguments = arguments
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
        guard stopped else { lock.unlock(); return }
        stopped = false
        lock.unlock()
        spawn()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let child = pid
        lock.unlock()

        // Signal only. The read loop owns the descriptor and closes it once
        // the kill drops the write end and `read` returns EOF. Closing it here
        // as well would be a double close, and fd numbers get reused, so the
        // second close can land on an unrelated live descriptor.
        terminate(child)
        // An uncooperative source must not retain a read thread or survive a
        // reload. The read loop clears pid after reaping, preventing a delayed
        // signal from hitting a reused pid.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.stopped, self.pid == child, child > 0 else { return }
            kill(-child, SIGKILL)
            kill(child, SIGKILL)
        }
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
        return pid > 0 && !stopped
    }

    private func spawn() {
        guard !executable.isEmpty,
              ([executable] + arguments).allSatisfy({ !$0.utf8.contains(0) }) else { return }
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
        let status = withCStringArray([executable] + arguments) { argv in
            withCStringArray(environment) { envp in
                posix_spawnp(&child, executable, &actions, &attributes, argv, envp)
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
            kill(-child, SIGKILL)
            kill(child, SIGKILL)
            close(fds[0])
            var ignored: Int32 = 0
            waitpid(child, &ignored, 0)
            return
        }

        let readFD = fds[0]
        let childPID = child
        queue.async { [self] in
            self.readLines(from: readFD)

            var exitStatus: Int32 = 0
            while waitpid(childPID, &exitStatus, 0) < 0, errno == EINTR {}

            self.lock.lock()
            if self.pid == childPID { self.pid = 0 }
            self.lock.unlock()

            self.scheduleRestart()
        }
    }

    private func readLines(from fd: Int32) {
        defer { close(fd) }
        var pending = Data()
        var discardingLongLine = false
        let maximumLineBytes = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: buffer[0 ..< count])

            // A stream can deliver partial lines, so only dispatch complete ones.
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex ..< newline]
                let tooLong = discardingLongLine || lineData.count > maximumLineBytes
                pending.removeSubrange(pending.startIndex ... newline)
                discardingLongLine = false
                guard !tooLong else { continue }

                let line = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }

                // A live stream means the source is healthy; reset backoff.
                lock.lock()
                restartDelay = 0.5
                lock.unlock()

                // Apply backpressure if the main thread cannot consume a
                // noisy source. Queueing unlimited callbacks defeats the line
                // size cap just as effectively as one unlimited line.
                while pendingLines.wait(timeout: .now() + 0.1) != .success {
                    lock.lock()
                    let halted = stopped
                    lock.unlock()
                    if halted { return }
                }
                let gate = pendingLines
                DispatchQueue.main.async { [weak self] in
                    defer { gate.signal() }
                    guard let self else { return }
                    self.lock.lock()
                    let active = !self.stopped
                    self.lock.unlock()
                    guard active else { return }
                    MainActor.assumeIsolated { self.onLine(line) }
                }
            }
            if pending.count > maximumLineBytes {
                pending.removeAll(keepingCapacity: true)
                discardingLongLine = true
            }
        }
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
/// Watches the file and its containing directory. Apps that write state
/// atomically (temp file, delete, rename) destroy
/// the inode on every write, so a watch bound to the file itself dies after
/// the first change and any recovery races the gap where the file does not
/// exist. A directory watch has no such gap.
public final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "funkybar.filewatch", qos: .utility)

    // Confined to queue, including start/stop. Generation checks also suppress
    // deliveries that were already queued on main when the watcher stopped.
    private var sources: [DispatchSourceFileSystemObject] = []
    private var running = false
    private var generation = UUID()
    private var pending: DispatchWorkItem?
    private var stamp: Stamp?

    private struct Stamp: Equatable {
        let resolved: String
        let exists: Bool
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }

    public init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path
        self.onChange = onChange
    }

    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            generation = UUID()
            stamp = currentStamp()
            watchPaths()
            if currentStamp() != stamp { scheduleChange() }
        }
    }

    public func stop() {
        queue.sync {
            running = false
            generation = UUID()
            pending?.cancel()
            pending = nil
            for source in sources { source.cancel() }
            sources.removeAll()
        }
    }

    deinit {
        pending?.cancel()
        for source in sources { source.cancel() }
    }

    private func currentStamp() -> Stamp {
        let resolved = (path as NSString).resolvingSymlinksInPath
        var info = stat()
        let exists = stat(path, &info) == 0
        return Stamp(resolved: resolved, exists: exists, inode: UInt64(info.st_ino),
                     size: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec,
                     modifiedNanos: info.st_mtimespec.tv_nsec,
                     changedSeconds: info.st_ctimespec.tv_sec,
                     changedNanos: info.st_ctimespec.tv_nsec)
    }

    private func watchPaths() {
        for source in sources { source.cancel() }
        sources.removeAll()
        guard running else { return }

        // Watch both the symlink's directory and its target's directory. If a
        // directory does not exist yet, watch its nearest existing ancestor so
        // creating the missing directories restores the watch automatically.
        var directories = Set<String>()
        for file in [path, (path as NSString).resolvingSymlinksInPath] {
            var directory = (file as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
                    || !isDirectory.boolValue {
                let parent = (directory as NSString).deletingLastPathComponent
                guard parent != directory, !parent.isEmpty else { break }
                directory = parent
            }
            directories.insert(directory)
        }

        // Directory events cover replacement, but do not report writes to an
        // existing file's contents. Watch the live file as well for writers
        // such as `echo value > state` and editors that save in place.
        var paths = directories
        for file in [path, (path as NSString).resolvingSymlinksInPath] {
            var info = stat()
            if stat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG { paths.insert(file) }
        }
        for watchedPath in paths {
            let descriptor = open(watchedPath, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .link, .rename, .delete, .revoke, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.scheduleChange() }
            source.setCancelHandler { close(descriptor) }
            source.activate()
            sources.append(source)
        }
    }

    private func scheduleChange() {
        guard running else { return }
        pending?.cancel()
        let generation = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == generation else { return }
            let newStamp = self.currentStamp()
            let changed = newStamp != self.stamp
            self.stamp = newStamp
            self.watchPaths()
            if self.currentStamp() != newStamp { self.scheduleChange() }
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let active = self.queue.sync { self.running && self.generation == generation }
                guard active else { return }
                MainActor.assumeIsolated { self.onChange() }
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
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
