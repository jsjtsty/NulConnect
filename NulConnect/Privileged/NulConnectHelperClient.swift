import Foundation
import Dispatch

nonisolated enum NulConnectHelperClientError: LocalizedError {
    case helperNotInstalled
    case helperNotRunning
    case bundledHelperNotFound
    case invalidResponse
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return "特权组件尚未安装"
        case .helperNotRunning:
            return "特权组件尚未启动"
        case .bundledHelperNotFound:
            return "找不到内置特权组件"
        case .invalidResponse:
            return "特权组件返回了无效响应"
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
        let needs = try needsInstallOrUpgrade()
        print("[NulConnect][Helper] ensureInstalledOrUpToDate: needs=\(needs)")
        if needs {
            try await installOrUpgrade(reporter: reporter)
        } else if !isRunning() {
            try await startInstalledHelper(reporter: reporter)
        }
    }

    func requiresInstallOrUpgrade() throws -> Bool {
        let needs = try needsInstallOrUpgrade()
        print("[NulConnect][Helper] requiresInstallOrUpgrade: needs=\(needs)")
        return needs
    }

    func installOrUpgrade(reporter: ActivityReporter? = nil) async throws {
        print("[NulConnect][Helper] installOrUpgrade: starting")
        if let reporter {
            await reporter(.installing(message: "正在请求管理员授权并安装特权组件"))
        }
        let helperURL = try bundledHelperURL()
        print("[NulConnect][Helper] installOrUpgrade: bundled helper at \(helperURL.path)")
        if let reporter {
            await reporter(.installing(message: "正在复制 helper 和启动项"))
        }
        let plist = try propertyListXMLString(from: launchDaemonPlistObject())
        let script = """
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(Self.installDirectory))
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(Self.stateDirectory))
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
            await reporter(.waitingForStart(message: "特权组件已安装，正在等待服务启动"))
        }
        try waitForSocket()
        print("[NulConnect][Helper] installOrUpgrade: completed successfully")
        if let reporter {
            await reporter(.succeeded(message: "特权组件已安装并启动"))
        }
    }

    private func startInstalledHelper(reporter: ActivityReporter? = nil) async throws {
        print("[NulConnect][Helper] startInstalledHelper: starting")
        if let reporter {
            await reporter(.waitingForStart(message: "正在启动特权组件"))
        }
        let script = """
        launchctl bootstrap system \(NulConnectPrivilegedExecutor.shellQuote(Self.launchDaemonPath)) >/dev/null 2>&1 || true
        launchctl kickstart -k system/\(Self.label)
        """
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "helper-start")
        try waitForSocket()
        print("[NulConnect][Helper] startInstalledHelper: completed")
    }

    private func needsInstallOrUpgrade() throws -> Bool {
        guard isInstalled() else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: not installed")
            return true
        }
        let bundled = try Data(contentsOf: bundledHelperURL())
        guard let installed = try? Data(contentsOf: URL(fileURLWithPath: Self.installedHelperPath)) else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: cannot read installed binary")
            return true
        }
        if bundled != installed {
            print("[NulConnect][Helper] needsInstallOrUpgrade: binary mismatch (bundled=\(bundled.count) bytes, installed=\(installed.count) bytes)")
            return true
        }

        guard let currentPlist = try? Data(contentsOf: URL(fileURLWithPath: Self.launchDaemonPath)),
              let currentObject = try? PropertyListSerialization.propertyList(from: currentPlist, options: [], format: nil) as? [String: Any] else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: cannot read current plist")
            return true
        }

        let expectedPlist = launchDaemonPlistObject()
        guard let expectedLabel = expectedPlist["Label"] as? String,
              let expectedProgramArguments = expectedPlist["ProgramArguments"] as? [String],
              let expectedGroupName = expectedPlist["GroupName"] as? String,
              let expectedRunAtLoad = expectedPlist["RunAtLoad"] as? Bool,
              let expectedKeepAlive = expectedPlist["KeepAlive"] as? Bool,
              let expectedStdout = expectedPlist["StandardOutPath"] as? String,
              let expectedStderr = expectedPlist["StandardErrorPath"] as? String else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: expected plist malformed")
            return true
        }

        let currentLabel = currentObject["Label"] as? String
        let currentProgramArguments = currentObject["ProgramArguments"] as? [String]
        let currentGroupName = currentObject["GroupName"] as? String
        let currentRunAtLoad = currentObject["RunAtLoad"] as? Bool
        let currentKeepAlive = currentObject["KeepAlive"] as? Bool
        let currentStdout = currentObject["StandardOutPath"] as? String
        let currentStderr = currentObject["StandardErrorPath"] as? String

        let plistDiffers =
            currentLabel != expectedLabel ||
            currentProgramArguments != expectedProgramArguments ||
            currentGroupName != expectedGroupName ||
            currentRunAtLoad != expectedRunAtLoad ||
            currentKeepAlive != expectedKeepAlive ||
            currentStdout != expectedStdout ||
            currentStderr != expectedStderr

        if plistDiffers {
            print("[NulConnect][Helper] needsInstallOrUpgrade: plist differs (label=\(currentLabel ?? "nil") expected=\(expectedLabel), argsMatch=\(currentProgramArguments == expectedProgramArguments), group=\(currentGroupName ?? "nil"), runAtLoad=\(currentRunAtLoad.map(String.init) ?? "nil"), keepAlive=\(currentKeepAlive.map(String.init) ?? "nil"), stdout=\(currentStdout ?? "nil"), stderr=\(currentStderr ?? "nil"))")
        } else {
            print("[NulConnect][Helper] needsInstallOrUpgrade: up to date")
        }
        return plistDiffers
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
        throw NulConnectHelperClientError.commandFailed("特权组件已安装，但服务未及时启动")
    }

    func status() async throws -> [String: Any] {
        try await send(command: ["command": "status"])
    }

    func version() async throws -> [String: Any] {
        try await send(command: ["command": "version"])
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
            print("[NulConnect][Helper] send: request=\(String(decoding: requestData, as: UTF8.self))")

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 {
                let err = errno
                print("[NulConnect][Helper] send: FAILED - socket(): \(String(cString: strerror(err)))")
                throw NulConnectHelperClientError.commandFailed("无法创建 socket: \(String(cString: strerror(err)))")
            }
            defer { Darwin.close(fd) }

            var tv = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let connectResult = Self.connectUnixSocket(fd, path: Self.socketPath)
            if connectResult < 0 {
                print("[NulConnect][Helper] send: FAILED - connect(): \(String(cString: strerror(-connectResult)))")
                throw NulConnectHelperClientError.commandFailed("无法连接特权组件: \(String(cString: strerror(-connectResult)))")
            }
            print("[NulConnect][Helper] send: connected")

            // Write
            let written = try Self.writeAll(fd, data: requestLine)
            print("[NulConnect][Helper] send: wrote \(written) bytes")

            // Read response line
            let responseData = try Self.readLine(fd)
            let responseStr = String(decoding: responseData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[NulConnect][Helper] send: response=\(responseStr)")

            guard let obj = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let ok = obj["ok"] as? Bool else {
                print("[NulConnect][Helper] send: FAILED - invalid response")
                throw NulConnectHelperClientError.invalidResponse
            }
            if ok {
                return obj["data"] as? [String: Any] ?? [:]
            }
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "特权组件命令失败"
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
                    throw NulConnectHelperClientError.commandFailed("写入失败: \(String(cString: strerror(err)))")
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
            if n == 0 { throw NulConnectHelperClientError.commandFailed("特权组件关闭了连接") }
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { throw NulConnectHelperClientError.commandFailed("读取响应超时") }
                throw NulConnectHelperClientError.commandFailed("读取失败: \(String(cString: strerror(err)))")
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

        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/libreatrust/dynamic/nulconnect-helper")
        if FileManager.default.fileExists(atPath: developmentURL.path) {
            return developmentURL
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
                Self.stateDirectory
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
            throw NulConnectHelperClientError.commandFailed("无法生成 LaunchDaemon plist")
        }
        return string
    }
}

private nonisolated func makeHelperJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}
