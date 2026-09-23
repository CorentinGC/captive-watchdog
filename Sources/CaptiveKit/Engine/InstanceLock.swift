import Foundation

public enum InstanceLockError: Error, CustomStringConvertible {
    case cannotOpen(String, Int32)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let code): return "verrou illisible \(path) (errno \(code))"
        }
    }
}

/// Garantit qu'un seul moteur tourne (CLI ou app). Le verrou flock disparaît
/// avec le processus : pas de verrou fantôme après un crash.
public final class InstanceLock {
    public let url: URL
    private var fd: Int32 = -1

    public init(url: URL) { self.url = url }

    deinit { release() }

    public func acquire() throws -> Bool {
        guard fd < 0 else { return true }
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw InstanceLockError.cannotOpen(url.path, errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        ftruncate(descriptor, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        fd = descriptor
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    public static func holderPID(at url: URL) -> pid_t? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
