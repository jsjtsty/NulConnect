import Foundation
import Darwin

nonisolated enum NulConnectDiagnostics {
    private static let lock = NSLock()
    private static let maximumLogSize: UInt64 = 5 * 1024 * 1024
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NulConnect/NulConnect.log")

    static func log(_ message: String) {
        print(message)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            rotateLogIfNeeded(adding: UInt64(data.count))
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("[NulConnect][Diagnostics] failed to write log: \(error)\n", stderr)
        }
    }

    private static func rotateLogIfNeeded(adding bytes: UInt64) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? NSNumber,
            size.uint64Value + bytes > maximumLogSize
        else { return }

        let previousURL = logURL.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: logURL, to: previousURL)
    }

    static func logCommand(label: String, executable: String, arguments: [String], timeoutSeconds: TimeInterval = 3) async {
        let output = await runCommand(executable: executable, arguments: arguments, timeoutSeconds: timeoutSeconds)
        log("[NulConnect][Diagnostics] \(label):\n\(output)")
    }

    static func logNetworkSnapshot(reason: String) async {
        log("[NulConnect][Diagnostics] network snapshot begin: \(reason)")
        await logCommand(label: "route default", executable: "/sbin/route", arguments: ["-n", "get", "default"])
        await logCommand(label: "route 198.18.0.1", executable: "/sbin/route", arguments: ["-n", "get", "198.18.0.1"])
        await logCommand(label: "netstat inet", executable: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        await logCommand(label: "dns", executable: "/usr/sbin/scutil", arguments: ["--dns"], timeoutSeconds: 5)
        log("[NulConnect][Diagnostics] network snapshot end: \(reason)")
    }

    private static func runCommand(executable: String, arguments: [String], timeoutSeconds: TimeInterval) async -> String {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return "failed to run \(executable): \(error.localizedDescription)"
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                return "timed out after \(timeoutSeconds)s"
            }

            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(empty)" : trimmed
        }.value
    }
}
