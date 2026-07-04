import Foundation

nonisolated enum NulConnectDiagnostics {
    private static let queue = DispatchQueue(label: "com.nulstudio.NulConnect.diagnostics")

    private static var logFileURL: URL {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NulConnect", isDirectory: true)
        return logsDirectory.appendingPathComponent("app.log", isDirectory: false)
    }

    static func log(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        print(message)
        queue.async {
            do {
                let url = logFileURL
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    try Data().write(to: url)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                print("[NulConnect][Diagnostics] failed to write app log: \(error.localizedDescription)")
            }
        }
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
                Thread.sleep(forTimeInterval: 0.05)
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

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
