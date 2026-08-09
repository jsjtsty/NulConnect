import Foundation

#if NULCONNECT_VERBOSE_LOGS
private final class NulConnectLogWriter: @unchecked Sendable {
    nonisolated static let shared = NulConnectLogWriter()

    private let lock = NSLock()
    private let fileURL: URL?

    private init() {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }

        let logDirectory = applicationSupport.appendingPathComponent("NulConnect", isDirectory: true)
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            fileURL = logDirectory.appendingPathComponent("NulConnect.log", isDirectory: false)
        } catch {
            fileURL = nil
            Swift.print("[NulConnect][Logging] failed to create log directory: \(error)")
        }
    }

    nonisolated func write(_ message: String, terminator: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\(terminator)"

        lock.lock()
        defer { lock.unlock() }

        guard let fileURL else { return }
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            Swift.print("[NulConnect][Logging] failed to write log: \(error)")
        }
    }
}
#endif

@inline(__always)
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if NULCONNECT_VERBOSE_LOGS
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(message, terminator: terminator)
    NulConnectLogWriter.shared.write(message, terminator: terminator)
#else
    _ = items
    _ = separator
    _ = terminator
#endif
}
