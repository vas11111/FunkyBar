import Darwin
import Foundation

/// Configs can contain shell actions, so read them as trusted local code.
/// Validate the opened descriptor, following symlinks without a stat/open race.
public enum ConfigFile {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable, notRegular, untrustedOwner, writableByOthers, tooLarge, invalidUTF8

        public var description: String {
            switch self {
            case .unreadable: "cannot read config file"
            case .notRegular: "config must be a regular file"
            case .untrustedOwner: "config must be owned by the current user or root"
            case .writableByOthers: "config must not be writable by group or others (use chmod go-w)"
            case .tooLarge: "config exceeds the 1 MiB limit"
            case .invalidUTF8: "config must be valid UTF-8"
            }
        }
    }

    public static func read(_ path: String) throws -> String {
        try read(path, limit: 1024 * 1024, trusted: true)
    }

    static func readState(_ path: String) throws -> String {
        try read(path, limit: 64 * 1024, trusted: false)
    }

    private static func read(_ path: String, limit: Int, trusted: Bool) throws -> String {
        guard !path.utf8.contains(0) else { throw Failure.unreadable }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegular }
        if trusted {
            guard info.st_uid == geteuid() || info.st_uid == 0 else { throw Failure.untrustedOwner }
            guard info.st_mode & 0o022 == 0 else { throw Failure.writableByOthers }
        }
        guard info.st_size <= limit else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unreadable }
            if count == 0 { break }
            guard data.count + count <= limit else { throw Failure.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidUTF8 }
        return text
    }
}
