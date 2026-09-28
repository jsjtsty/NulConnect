import Foundation

nonisolated enum NulConnectPrivilegedExecutorError: LocalizedError {
    case scriptEncodingFailed
    case launchFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptEncodingFailed:
            return NulConnectLocalization.text("Could not encode the privileged script")
        case .launchFailed(let message):
            return NulConnectLocalization.format("Could not request administrator privileges: %1$@", [String(describing: message)])
        case .commandFailed(let message):
            return NulConnectLocalization.format("Privileged command failed: %1$@", [String(describing: message)])
        }
    }
}

nonisolated enum NulConnectPrivilegedExecutor {
    static func runShellScript(_ body: String, name: String) throws {
        // The script travels as an argument instead of through a temporary
        // file, so no other process of this user can swap it between writing
        // and the administrator-authorized execution.
        let script = """
        set -eu
        \(body)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            script
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw NulConnectPrivilegedExecutorError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let stdout = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let message = [stdout, stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            NulConnectDiagnostics.log("[NulConnect][Privileged] \(name) failed: \(message)")
            throw NulConnectPrivilegedExecutorError.commandFailed(
                message.isEmpty ? "unknown error" : message
            )
        }
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
