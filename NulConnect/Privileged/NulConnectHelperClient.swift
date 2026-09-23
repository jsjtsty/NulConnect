import Foundation
import Dispatch
import Darwin

nonisolated enum NulConnectHelperClientError: LocalizedError {
    case helperNotInstalled
    case helperNotRunning
    case bundledHelperNotFound
    case invalidResponse
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return NulConnectLocalization.text("Privileged component is not installed")
        case .helperNotRunning:
            return NulConnectLocalization.text("Privileged component is not running")
        case .bundledHelperNotFound:
            return NulConnectLocalization.text("Bundled privileged component was not found")
        case .invalidResponse:
            return NulConnectLocalization.text("Privileged component returned an invalid response")
        case .commandFailed(let message):
            return message
        }
    }
}

nonisolated final class NulConnectHelperClient: @unchecked Sendable {
    typealias ActivityReporter = @MainActor @Sendable (NulConnectHelperActivityState) -> Void

    static let socketPath = "/var/run/nulconnect-helper.sock"
    static let installDirectory = "/Library/PrivilegedHelperTools/NulConnect"
    static let installedHelperPath = "/Library/PrivilegedHelperTools/NulConnect/nulconnect-helper"
    static let launchDaemonPath = "/Library/LaunchDaemons/com.nulstudio.NulConnect.helper.plist"
    static let stateDirectory = "/Library/Application Support/NulConnect"
    static let label = "com.nulstudio.NulConnect.helper"

    func isInstalled() -> Bool {
        let hasBinary = FileManager.default.fileExists(atPath: Self.installedHelperPath)
        let hasPlist = FileManager.default.fileExists(atPath: Self.launchDaemonPath)
        return hasBinary && hasPlist
    }

    private func isConfiguredForCurrentUser() -> Bool {
        guard let data = FileManager.default.contents(atPath: Self.launchDaemonPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.count >= 6 else {
            return false
        }
        return arguments[4] == String(getuid()) && arguments[5] == String(getgid())
    }

    func isRunning() -> Bool {
        let running = FileManager.default.fileExists(atPath: Self.socketPath)
        print("[NulConnect][Helper] isRunning: socket exists=\(running), path=\(Self.socketPath)")
        if running {
            if let attr = try? FileManager.default.attributesOfItem(atPath: Self.socketPath),
               let type = attr[.type] as? FileAttributeType {
                print("[NulConnect][Helper] socket file type: \(type)")
            }
            if let attr = try? FileManager.default.attributesOfItem(atPath: Self.socketPath),
               let perm = attr[.posixPermissions] as? UInt {
                print("[NulConnect][Helper] socket permissions: 0\(String(perm, radix: 8))")
            }
            // Check if helper process is actually alive
            if let pid = helperPid() {
                print("[NulConnect][Helper] isRunning: helper PID=\(pid)")
            } else {
                print("[NulConnect][Helper] isRunning: WARNING - socket exists but no helper process found (stale socket)")
            }
        }
        return running
    }

    func helperPid() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", Self.installedHelperPath + " serve"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = lines.first, let pid = pid_t(first) {
            return pid
        }
        return nil
    }

    func ensureInstalledOrUpToDate(reporter: ActivityReporter? = nil) async throws {
        let needs = try await needsInstallOrUpgrade()
        print("[NulConnect][Helper] ensureInstalledOrUpToDate: needs=\(needs)")
        if needs {
            try await installOrUpgrade(reporter: reporter)
        } else if !isRunning() {
            try await startInstalledHelper(reporter: reporter)
        }
    }

    func requiresInstallOrUpgrade() async throws -> Bool {
        let needs = try await needsInstallOrUpgrade()
        print("[NulConnect][Helper] requiresInstallOrUpgrade: needs=\(needs)")
        return needs
    }

    func installOrUpgrade(reporter: ActivityReporter? = nil) async throws {
        print("[NulConnect][Helper] installOrUpgrade: starting")
        if let reporter {
            await reporter(.installing(message: NulConnectLocalization.text("Requesting administrator authorization and installing the privileged component")))
        }
        let helperURL = try bundledHelperURL()
        print("[NulConnect][Helper] installOrUpgrade: bundled helper at \(helperURL.path)")
        if let reporter {
            await reporter(.installing(message: NulConnectLocalization.text("Copying the helper and launch item")))
        }
        let plist = try propertyListXMLString(from: launchDaemonPlistObject())
        let script = """
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(Self.installDirectory))
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(Self.stateDirectory))
        rm -f /Library/Logs/NulConnect/helper.log
        cp -f \(NulConnectPrivilegedExecutor.shellQuote(helperURL.path)) \(NulConnectPrivilegedExecutor.shellQuote(Self.installedHelperPath))
        chown root:wheel \(NulConnectPrivilegedExecutor.shellQuote(Self.installedHelperPath))
        chmod 755 \(NulConnectPrivilegedExecutor.shellQuote(Self.installedHelperPath))
        cat > \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath)) <<'NULCONNECT_PLIST'
        \(plist)
        NULCONNECT_PLIST
        chown root:wheel \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath))
        chmod 644 \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath))
        launchctl bootout system/\(Self.label) >/dev/null 2>&1 || true
        launchctl bootstrap system \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath))
        launchctl kickstart -k system/\(Self.label)
        """
        print("[NulConnect][Helper] installOrUpgrade: executing privileged install script")
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "helper-install")
        print("[NulConnect][Helper] installOrUpgrade: privileged script completed, waiting for socket")
        if let reporter {
            await reporter(.waitingForStart(message: NulConnectLocalization.text("Privileged component installed; waiting for the service to start")))
        }
        try waitForSocket()
        print("[NulConnect][Helper] installOrUpgrade: completed successfully")
        if let reporter {
            await reporter(.succeeded(message: NulConnectLocalization.text("Privileged component installed and started")))
        }
    }

    private func startInstalledHelper(reporter: ActivityReporter? = nil) async throws {
        print("[NulConnect][Helper] startInstalledHelper: starting")
        if let reporter {
            await reporter(.waitingForStart(message: NulConnectLocalization.text("Starting privileged component")))
        }
        let script = """
        launchctl bootstrap system \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath)) >/dev/null 2>&1 || true
        launchctl kickstart -k system/\(Self.label)
        """
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "helper-start")
        try waitForSocket()
        print("[NulConnect][Helper] startInstalledHelper: completed")
    }

    private func needsInstallOrUpgrade() async throws -> Bool {
        guard isInstalled() else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: not installed")
            return true
        }
        guard isConfiguredForCurrentUser() else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: helper belongs to another user or uses an obsolete launch configuration")
            return true
        }
        async let installedVersion = installedVersionString()
        async let bundledVersion = bundledVersionString()
        let installed = await installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundled = await bundledVersion?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let installed, !installed.isEmpty else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: installed version unavailable")
            return true
        }
        guard let bundled, !bundled.isEmpty else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: bundled version unavailable")
            return true
        }

        guard let comparison = Self.compareVersionStrings(installed, bundled) else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: version compare failed (installed=\(installed), bundled=\(bundled))")
            return true
        }

        let needs = comparison == .orderedAscending
        print("[NulConnect][Helper] needsInstallOrUpgrade: version compare installed=\(installed) bundled=\(bundled) needs=\(needs)")
        return needs
    }

    func uninstall() throws {
        print("[NulConnect][Helper] uninstall: starting")
        let script = """
        launchctl bootout system/\(Self.label) >/dev/null 2>&1 || true
        rm -f \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath))
        rm -f \(NulConnectPrivilegedExecutor.shellQuote(Self.installedHelperPath))
        rm -f \(NulConnectPrivilegedExecutor.shellQuote(Self.socketPath))
        rm -rf \(NulConnectPrivilegedExecutor.shellQuote(Self.stateDirectory))
        """
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "helper-uninstall")
        print("[NulConnect][Helper] uninstall: completed")
    }

    private func waitForSocket() throws {
        print("[NulConnect][Helper] waitForSocket: waiting up to 6s for \(Self.socketPath)")
        let deadline = Date().addingTimeInterval(6)
        var count: Int = 0
        while Date() < deadline {
            if isRunning() {
                print("[NulConnect][Helper] waitForSocket: socket appeared after \(count) checks")
                return
            }
            count += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("[NulConnect][Helper] waitForSocket: timed out after \(count) checks")
        throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.text("Privileged component installed, but the service did not start in time"))
    }

    func status() async throws -> [String: Any] {
        try await send(command: ["command": "status"])
    }

    func version() async throws -> [String: Any] {
        try await send(command: ["command": "version"])
    }

    func installedVersionString() async -> String? {
        guard isInstalled() else {
            return nil
        }
        if isRunning(),
           let response = try? await version(),
           let version = response["version"] as? String,
           !version.isEmpty {
            return version
        }

        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.installedHelperPath)
            process.arguments = ["version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return output.isEmpty ? nil : output
            } catch {
                return nil
            }
        }.value
    }

    func bundledVersionString() async -> String? {
        guard let helperURL = try? bundledHelperURL() else {
            return nil
        }
        return await helperVersionString(at: helperURL)
    }

    private func helperVersionString(at url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = url
            process.arguments = ["version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return nil
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return output.isEmpty ? nil : output
            } catch {
                return nil
            }
        }.value
    }

    func startTun(configuration: NulConnectTunHelperConfiguration) async throws -> [String: Any] {
        let configData = try makeHelperJSONEncoder().encode(configuration)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw NulConnectHelperClientError.invalidResponse
        }
        return try await send(command: [
            "command": "start_tun",
            "config": config
        ])
    }

    func stopTun() async throws {
        _ = try await send(command: ["command": "stop_tun"])
    }

    func setSystemProxy(endpoint: NulConnectProxyEndpoint, serverHost: String) async throws -> Int {
        let response = try await send(command: [
            "command": "set_system_proxy",
            "endpoint": [
                "host": endpoint.host,
                "port": Int(endpoint.port)
            ],
            "server_host": serverHost
        ])
        return response["services"] as? Int ?? 0
    }

    func restoreSystemProxy() async throws {
        _ = try await send(command: ["command": "restore_system_proxy"])
    }

    func cleanup() async throws {
        _ = try await send(command: ["command": "cleanup"])
    }

    private func send(command: [String: Any]) async throws -> [String: Any] {
        let cmdName = command["command"] as? String ?? "unknown"
        print("[NulConnect][Helper] send: command=\(cmdName), socket=\(Self.socketPath)")

        guard isRunning() else {
            print("[NulConnect][Helper] send: FAILED - helper not running (socket missing)")
            throw NulConnectHelperClientError.helperNotRunning
        }

        return try await Task.detached(priority: .utility) {
            var request = command
            request["id"] = UUID().uuidString
            let requestData = try JSONSerialization.data(withJSONObject: request)
            let requestLine = Data(requestData + Data([0x0a]))
            // The "start_tun" request embeds session credentials (sid,
            // sign key, cookies); never log the raw request body.
            print("[NulConnect][Helper] send: request bytes=\(requestData.count)")

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 {
                let err = errno
                print("[NulConnect][Helper] send: FAILED - socket(): \(String(cString: strerror(err)))")
                throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.format("Could not create socket: %1$@", [String(describing: String(cString: strerror(err)))]))
            }
            defer { Darwin.close(fd) }

            var tv = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var noSIGPIPE: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

            let connectResult = Self.connectUnixSocket(fd, path: Self.socketPath)
            if connectResult < 0 {
                print("[NulConnect][Helper] send: FAILED - connect(): \(String(cString: strerror(-connectResult)))")
                throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.format("Could not connect to privileged component: %1$@", [String(describing: String(cString: strerror(-connectResult)))]))
            }
            print("[NulConnect][Helper] send: connected")

            // Write
            let written = try Self.writeAll(fd, data: requestLine)
            print("[NulConnect][Helper] send: wrote \(written) bytes")

            // Read response line
            let responseData = try Self.readLine(fd)
            print("[NulConnect][Helper] send: response bytes=\(responseData.count)")

            guard let obj = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let ok = obj["ok"] as? Bool else {
                print("[NulConnect][Helper] send: FAILED - invalid response")
                throw NulConnectHelperClientError.invalidResponse
            }
            if ok {
                return obj["data"] as? [String: Any] ?? [:]
            }
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? NulConnectLocalization.text("Privileged component command failed")
            print("[NulConnect][Helper] send: FAILED - \(msg)")
            throw NulConnectHelperClientError.commandFailed(msg)
        }.value
    }

    // MARK: - Unix socket helpers

    private static func connectUnixSocket(_ fd: Int32, path: String) -> Int32 {
        let cstr = path.cString(using: .utf8)!
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: MemoryLayout<sockaddr_un>.size) { buf in
            buf.initialize(repeating: 0)
            return buf.baseAddress!.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { addrPtr in
                var addr = addrPtr.pointee
                addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!)
                addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                    let dest = UnsafeMutableRawPointer(mutating: pathPtr).bindMemory(to: CChar.self, capacity: 108)
                    Darwin.memcpy(dest, cstr, cstr.count)
                }
                return withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
        }
    }

    private static func writeAll(_ fd: Int32, data: Data) throws -> Int {
        try data.withUnsafeBytes { buffer in
            let ptr = buffer.bindMemory(to: CChar.self).baseAddress!
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, ptr.advanced(by: sent), data.count - sent)
                if n < 0 {
                    let err = errno
                    if err == EPIPE {
                        throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.text("Privileged component disconnected"))
                    }
                    throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.format("Write failed: %1$@", [String(describing: String(cString: strerror(err)))]))
                }
                sent += n
            }
            return sent
        }
    }

    private static func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var buf = [Int8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress!, 4096)
            }
            if n == 0 { throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.text("Privileged component closed the connection")) }
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.text("Timed out waiting for a response")) }
                throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.format("Read failed: %1$@", [String(describing: String(cString: strerror(err)))]))
            }
            let bytes = Data(bytes: buf, count: n)
            result.append(bytes)
            if bytes.contains(where: { $0 == 0x0a }) { break }
            if result.count > 1024 * 1024 { throw NulConnectHelperClientError.invalidResponse }
        }
        return result
    }

    private func bundledHelperURL() throws -> URL {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("nulconnect-helper"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        throw NulConnectHelperClientError.bundledHelperNotFound
    }

    private func launchDaemonPlistObject() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [
                Self.installedHelperPath,
                "serve",
                Self.socketPath,
                Self.stateDirectory,
                String(getuid()),
                String(getgid())
            ],
            "GroupName": "staff",
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
    }

    private func propertyListXMLString(from object: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw NulConnectHelperClientError.commandFailed(NulConnectLocalization.text("Could not generate the LaunchDaemon plist"))
        }
        return string
    }

    private static func compareVersionStrings(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        let left = normalizedVersionParts(lhs)
        let right = normalizedVersionParts(rhs)

        guard !left.numeric.isEmpty || !right.numeric.isEmpty else {
            return nil
        }

        let numericComparison = left.numeric.compare(right.numeric, options: [.numeric])
        if numericComparison != .orderedSame {
            return numericComparison
        }

        switch (left.suffix.isEmpty, right.suffix.isEmpty) {
        case (true, true):
            return .orderedSame
        case (true, false):
            return .orderedDescending
        case (false, true):
            return .orderedAscending
        case (false, false):
            return left.suffix.compare(right.suffix, options: [.numeric])
        }
    }

    private static func normalizedVersionParts(_ version: String) -> (numeric: String, suffix: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let splitIndex = body.firstIndex { !$0.isNumber && $0 != "." } ?? body.endIndex
        let numeric = String(body[..<splitIndex])
        let suffix = String(body[splitIndex...])
        return (numeric: numeric, suffix: suffix)
    }
}

private nonisolated func makeHelperJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}
