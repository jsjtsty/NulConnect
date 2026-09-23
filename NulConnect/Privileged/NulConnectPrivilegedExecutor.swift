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
        let script = """
        #!/bin/sh
        set -eu
        \(body)
        """

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NulConnect-Privileged", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let scriptURL = tempDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString).sh",
            isDirectory: false
        )
        guard let scriptData = script.data(using: .utf8) else {
            throw NulConnectPrivilegedExecutorError.scriptEncodingFailed
        }
        try scriptData.write(to: scriptURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let command = "do shell script \(appleScriptStringLiteral("/bin/sh \(shellQuote(scriptURL.path))")) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", command]

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
            throw NulConnectPrivilegedExecutorError.commandFailed(
                message.isEmpty ? "unknown error" : message
            )
        }
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptStringLiteral(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
