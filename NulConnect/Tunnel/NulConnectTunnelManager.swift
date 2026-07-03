import Foundation

nonisolated enum NulConnectTunnelManagerError: LocalizedError {
    case helperNotFound
    case helperStateUnavailable
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "找不到 TUN 特权组件"
        case .helperStateUnavailable:
            return "无法读取 TUN 运行状态"
        case .helperFailed(let message):
            return "TUN 特权组件失败: \(message)"
        }
    }
}

nonisolated final class NulConnectTunnelManager: @unchecked Sendable {
    private let stateDirectory: URL

    init(baseDirectory: URL? = nil) throws {
        let root = try NulConnectStorageDirectory.rootDirectory(override: baseDirectory)
        self.stateDirectory = root.appendingPathComponent("tun", isDirectory: true)
    }

    func start(configuration: NulConnectTunnelLaunchConfiguration) async throws {
        let stateDirectory = self.stateDirectory
        try await Task.detached(priority: .utility) {
            try Self.startSync(configuration: configuration, stateDirectory: stateDirectory)
        }.value
    }

    func stop() async throws {
        let stateDirectory = self.stateDirectory
        try await Task.detached(priority: .utility) {
            try Self.stopSync(stateDirectory: stateDirectory)
        }.value
    }

    func loadState() throws -> NulConnectTunHelperState? {
        let stateURL = stateDirectory.appendingPathComponent("state.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: stateURL)
        return try makeTunnelJSONDecoder().decode(NulConnectTunHelperState.self, from: data)
    }

    private static func startSync(
        configuration: NulConnectTunnelLaunchConfiguration,
        stateDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        let configURL = stateDirectory.appendingPathComponent("config.json", isDirectory: false)
        let stateURL = stateDirectory.appendingPathComponent("state.json", isDirectory: false)
        let stopURL = stateDirectory.appendingPathComponent("stop", isDirectory: false)
        let logURL = stateDirectory.appendingPathComponent("helper.log", isDirectory: false)
        let helperURL = try helperExecutableURL()

        let helperConfig = NulConnectTunHelperConfiguration(
            proxyURL: "socks5://\(configuration.proxyEndpoint.host):\(configuration.proxyEndpoint.port)",
            tunName: nil,
            dnsStrategy: "virtual",
            dnsAddress: "8.8.8.8",
            virtualDNSPool: "198.18.0.0/15",
            bypassCIDRs: [],
            mtu: configuration.mtu,
            tcpTimeoutSeconds: 600,
            udpTimeoutSeconds: 30,
            maxSessions: 512,
            setupRoutes: configuration.setupRoutes,
            ipv6Enabled: false,
            packetInformation: true,
            exitOnFatalError: false,
            verbosity: "warn"
        )
        let data = try makeTunnelJSONEncoder().encode(helperConfig)
        try data.write(to: configURL, options: [.atomic])
        try? FileManager.default.removeItem(at: stopURL)
        try? FileManager.default.removeItem(at: stateURL)

        let script = """
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(stateDirectory.path))
        rm -f \(NulConnectPrivilegedExecutor.shellQuote(stopURL.path))
        chmod 755 \(NulConnectPrivilegedExecutor.shellQuote(helperURL.path))
        nohup \(NulConnectPrivilegedExecutor.shellQuote(helperURL.path)) run \(NulConnectPrivilegedExecutor.shellQuote(configURL.path)) \(NulConnectPrivilegedExecutor.shellQuote(stateURL.path)) \(NulConnectPrivilegedExecutor.shellQuote(stopURL.path)) > \(NulConnectPrivilegedExecutor.shellQuote(logURL.path)) 2>&1 &
        """
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "tun-start")
        try waitForRunningState(stateURL: stateURL, logURL: logURL)
    }

    private static func stopSync(stateDirectory: URL) throws {
        let stateURL = stateDirectory.appendingPathComponent("state.json", isDirectory: false)
        let stopURL = stateDirectory.appendingPathComponent("stop", isDirectory: false)
        let pid = readState(stateURL: stateURL)?.pid
        var script = """
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(stateDirectory.path))
        touch \(NulConnectPrivilegedExecutor.shellQuote(stopURL.path))
        """
        if let pid, pid > 0 {
            script += """

            sleep 2
            if kill -0 \(pid) 2>/dev/null; then
              kill -TERM \(pid) 2>/dev/null || true
              sleep 1
            fi
            if kill -0 \(pid) 2>/dev/null; then
              kill -KILL \(pid) 2>/dev/null || true
            fi
            """
        }
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "tun-stop")
    }

    private static func waitForRunningState(stateURL: URL, logURL: URL) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let state = readState(stateURL: stateURL) {
                switch state.status {
                case "running":
                    return
                case "failed":
                    throw NulConnectTunnelManagerError.helperFailed(
                        state.message ?? readLog(logURL: logURL) ?? "unknown error"
                    )
                default:
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NulConnectTunnelManagerError.helperFailed(
            readLog(logURL: logURL) ?? "helper did not report running state"
        )
    }

    private static func readState(stateURL: URL) -> NulConnectTunHelperState? {
        guard let data = try? Data(contentsOf: stateURL) else {
            return nil
        }
        return try? makeTunnelJSONDecoder().decode(NulConnectTunHelperState.self, from: data)
    }

    private static func readLog(logURL: URL) -> String? {
        guard let data = try? Data(contentsOf: logURL) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func helperExecutableURL() throws -> URL {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("nulconnect-tun-helper"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vendor/libreatrust/dynamic/nulconnect-tun-helper")
        if FileManager.default.fileExists(atPath: developmentURL.path) {
            return developmentURL
        }

        throw NulConnectTunnelManagerError.helperNotFound
    }
}

private nonisolated func makeTunnelJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private nonisolated func makeTunnelJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
