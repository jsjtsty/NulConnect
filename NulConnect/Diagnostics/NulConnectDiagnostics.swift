import Foundation
import Darwin

nonisolated enum NulConnectDiagnostics {
    static func log(_ message: String) {
        #if DEBUG && NULCONNECT_ENABLE_LOGS
        print(message)
        #else
        _ = message
        #endif
    }

    static func logCommand(label: String, executable: String, arguments: [String], timeoutSeconds: TimeInterval = 3) async {
        #if DEBUG && NULCONNECT_ENABLE_LOGS
        let output = await runCommand(executable: executable, arguments: arguments, timeoutSeconds: timeoutSeconds)
        log("[NulConnect][Diagnostics] \(label):\n\(output)")
        #else
        _ = (label, executable, arguments, timeoutSeconds)
        #endif
    }

    static func logNetworkSnapshot(reason: String) async {
        #if DEBUG && NULCONNECT_ENABLE_LOGS
        log("[NulConnect][Diagnostics] network snapshot begin: \(reason)")
        await logCommand(label: "route default", executable: "/sbin/route", arguments: ["-n", "get", "default"])
        await logCommand(label: "route 198.18.0.1", executable: "/sbin/route", arguments: ["-n", "get", "198.18.0.1"])
        await logCommand(label: "netstat inet", executable: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        await logCommand(label: "dns", executable: "/usr/sbin/scutil", arguments: ["--dns"], timeoutSeconds: 5)
        log("[NulConnect][Diagnostics] network snapshot end: \(reason)")
        #else
        _ = reason
        #endif
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
