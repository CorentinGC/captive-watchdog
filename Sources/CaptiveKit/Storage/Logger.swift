import Foundation

public final class Logger: @unchecked Sendable {
    public enum Level: String, Sendable {
        case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
    }

    public let url: URL?
    let echo: Bool
    let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL?, echo: Bool = false, maxBytes: Int = 2_000_000) {
        self.url = url
        self.echo = echo
        self.maxBytes = maxBytes
    }

    public func log(_ level: Level, _ message: String) {
        let data = Data("\(Format.timestamp(Date())) [\(level.rawValue)] \(message)\n".utf8)
        lock.locked {
            if echo { FileHandle.standardError.write(data) }
            guard let url else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + data.count > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }

    public func debug(_ message: String) { log(.debug, message) }
    public func info(_ message: String) { log(.info, message) }
    public func warn(_ message: String) { log(.warn, message) }
    public func error(_ message: String) { log(.error, message) }
}
