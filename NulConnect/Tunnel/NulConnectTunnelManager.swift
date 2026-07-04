import Foundation
import Darwin

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
    private let helperClient = NulConnectHelperClient()

    init(baseDirectory: URL? = nil) throws {
        let root = try NulConnectStorageDirectory.rootDirectory(override: baseDirectory)
        self.stateDirectory = root.appendingPathComponent("tun", isDirectory: true)
    }

    func start(
        configuration: NulConnectTunnelLaunchConfiguration,
        helperActivityReporter: NulConnectHelperClient.ActivityReporter? = nil
    ) async throws {
        NulConnectDiagnostics.log("[NulConnect][Tunnel] start: proxy=\(configuration.proxyEndpoint.host):\(configuration.proxyEndpoint.port), dns=\(configuration.dnsAddress), mtu=\(configuration.mtu), setupRoutes=\(configuration.setupRoutes), bypass=\(configuration.bypassCIDRs.count) [\(configuration.bypassCIDRs.prefix(12).joined(separator: ", "))], managedRoutes=\(configuration.managedRouteCIDRs.count) [\(configuration.managedRouteCIDRs.prefix(12).joined(separator: ", "))]")
        let helperRequiresInstallOrUpgrade = try helperClient.requiresInstallOrUpgrade()
        do {
            try await helperClient.ensureInstalledOrUpToDate(reporter: helperActivityReporter)
            let helperConfiguration = Self.makeHelperConfiguration(configuration)
            NulConnectDiagnostics.log("[NulConnect][Tunnel] start: helper config proxy=\(helperConfiguration.proxyURL) dnsStrategy=\(helperConfiguration.dnsStrategy) dns=\(helperConfiguration.dnsAddress) virtualPool=\(helperConfiguration.virtualDNSPool) setupRoutes=\(helperConfiguration.setupRoutes) ipv6=\(helperConfiguration.ipv6Enabled) mtu=\(helperConfiguration.mtu) tcpTimeout=\(helperConfiguration.tcpTimeoutSeconds) maxSessions=\(helperConfiguration.maxSessions) verbosity=\(helperConfiguration.verbosity)")
            let response = try await helperClient.startTun(configuration: helperConfiguration)
            NulConnectDiagnostics.log("[NulConnect][Tunnel] start: helper response=\(response)")
            try await waitForPersistentHelperRunning()
            NulConnectDiagnostics.log("[NulConnect][Tunnel] start via helper: success")
            return
        } catch {
            NulConnectDiagnostics.log("[NulConnect][Tunnel] start via helper: FAILED - \(error.localizedDescription)")
            if helperRequiresInstallOrUpgrade {
                throw error
            }
            if helperClient.isInstalled() {
                throw error
            }
            NulConnectDiagnostics.log("[NulConnect][Tunnel] falling back to legacy runner")
        }

        let stateDirectory = self.stateDirectory
        try await Task.detached(priority: .utility) {
            try Self.startSync(configuration: configuration, stateDirectory: stateDirectory)
            NulConnectDiagnostics.log("[NulConnect][Tunnel] start via legacy: success")
        }.value
    }

    func stop() async throws {
        NulConnectDiagnostics.log("[NulConnect][Tunnel] stop: starting")
        if helperClient.isInstalled() {
            do {
                try await helperClient.stopTun()
                NulConnectDiagnostics.log("[NulConnect][Tunnel] stop via helper: success")
                return
            } catch {
                NulConnectDiagnostics.log("[NulConnect][Tunnel] stop via helper: FAILED - \(error.localizedDescription)")
                throw error
            }
        }

        let stateDirectory = self.stateDirectory
        try await Task.detached(priority: .utility) {
            try Self.stopSync(stateDirectory: stateDirectory)
            NulConnectDiagnostics.log("[NulConnect][Tunnel] stop via legacy: success")
        }.value
    }

    func cleanupPrivilegedState() async throws {
        if helperClient.isRunning() {
            try await helperClient.cleanup()
        } else {
            NulConnectDiagnostics.log("[NulConnect][Tunnel] cleanupPrivilegedState: helper socket missing, skipping helper cleanup")
        }
    }

    func loadState() throws -> NulConnectTunHelperState? {
        let stateURL = stateDirectory.appendingPathComponent("state.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: stateURL)
        return try makeTunnelJSONDecoder().decode(NulConnectTunHelperState.self, from: data)
    }

    private func waitForPersistentHelperRunning() async throws {
        NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: waiting up to 6s")
        let deadline = Date().addingTimeInterval(6)
        var lastStatus: String?
        var count: Int = 0
        while Date() < deadline {
            let status = try await helperClient.status()
            NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: raw status=\(status)")
            if let tun = status["tun"] as? [String: Any] {
                let state = tun["status"] as? String
                lastStatus = state
                NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: check #\(count), tun state=\(state ?? "nil")")
                if state == "running" {
                    NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: TUN is running")
                    return
                }
                if state == "failed" {
                    let message = tun["message"] as? String ?? "tun helper reported failure"
                    NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: TUN failed - \(message)")
                    throw NulConnectTunnelManagerError.helperFailed(message)
                }
            } else {
                NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: check #\(count), no tun key in status")
            }
            count += 1
            try await Task.sleep(for: .milliseconds(200))
        }
        NulConnectDiagnostics.log("[NulConnect][Tunnel] waitForPersistentHelperRunning: timed out after \(count) checks, lastStatus=\(lastStatus ?? "nil")")
        throw NulConnectTunnelManagerError.helperFailed(
            "helper did not report running TUN state\(lastStatus.map { ": \($0)" } ?? "")"
        )
    }

    static func makeLaunchConfiguration(
        proxyEndpoint: NulConnectProxyEndpoint,
        resource: ATRResourceSnapshot,
        serverHost: String
    ) async -> NulConnectTunnelLaunchConfiguration {
        let dnsAddress = await preferredDNSServer(resource: resource)
        return NulConnectTunnelLaunchConfiguration(
            proxyEndpoint: proxyEndpoint,
            dnsAddress: dnsAddress,
            bypassCIDRs: await makeBypassCIDRs(resource: resource, serverHost: serverHost),
            managedRouteCIDRs: makeManagedRouteCIDRs(resource: resource),
            managedDomains: makeManagedDomains(resource: resource),
            setupRoutes: true
        )
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
        let helperURL = try helperExecutableURL()

        let helperConfig = makeHelperConfiguration(configuration)
        let data = try makeTunnelJSONEncoder().encode(helperConfig)
        try data.write(to: configURL, options: [.atomic])
        try? FileManager.default.removeItem(at: stopURL)
        try? FileManager.default.removeItem(at: stateURL)

        let script = """
        mkdir -p \(NulConnectPrivilegedExecutor.shellQuote(stateDirectory.path))
        rm -f \(NulConnectPrivilegedExecutor.shellQuote(stopURL.path))
        chmod 755 \(NulConnectPrivilegedExecutor.shellQuote(helperURL.path))
        nohup \(NulConnectPrivilegedExecutor.shellQuote(helperURL.path)) run \(NulConnectPrivilegedExecutor.shellQuote(configURL.path)) \(NulConnectPrivilegedExecutor.shellQuote(stateURL.path)) \(NulConnectPrivilegedExecutor.shellQuote(stopURL.path)) >/dev/null 2>&1 &
        """
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "tun-start")
        try waitForRunningState(stateURL: stateURL)
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
        try emergencyCleanupSync()
    }

    private static func emergencyCleanupSync() throws {
        let script = """
        /bin/launchctl bootout system/com.nulstudio.NulConnect.helper >/dev/null 2>&1 || true
        /usr/bin/pkill -f '/Library/PrivilegedHelperTools/NulConnect/nulconnect-helper' >/dev/null 2>&1 || true
        /usr/bin/pkill -f 'nulconnect-tun-helper run' >/dev/null 2>&1 || true
        /sbin/route -n delete -net 198.18.0.0/15 >/dev/null 2>&1 || true
        /sbin/route -n delete -net 198.18.0.0/16 >/dev/null 2>&1 || true
        /sbin/route -n delete -host 198.18.0.1 >/dev/null 2>&1 || true
        /usr/sbin/scutil >/dev/null 2>&1 <<'NULCONNECT_SCUTIL'
        remove State:/Network/Global/DNS
        quit
        NULCONNECT_SCUTIL
        /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2 | while IFS= read -r service; do
          [ -z "$service" ] && continue
          service="${service#\\* }"
          /usr/sbin/networksetup -setdnsservers "$service" Empty >/dev/null 2>&1 || true
          /usr/sbin/networksetup -setsearchdomains "$service" Empty >/dev/null 2>&1 || true
        done
        /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
        /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
        /usr/bin/killall configd >/dev/null 2>&1 || true
        """
        try NulConnectPrivilegedExecutor.runShellScript(script, name: "tun-emergency-cleanup")
    }

    private static func waitForRunningState(stateURL: URL) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let state = readState(stateURL: stateURL) {
                switch state.status {
                case "running":
                    return
                case "failed":
                    throw NulConnectTunnelManagerError.helperFailed(
                        state.message ?? "unknown error"
                    )
                default:
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NulConnectTunnelManagerError.helperFailed(
            "helper did not report running state"
        )
    }

    private static func readState(stateURL: URL) -> NulConnectTunHelperState? {
        guard let data = try? Data(contentsOf: stateURL) else {
            return nil
        }
        return try? makeTunnelJSONDecoder().decode(NulConnectTunHelperState.self, from: data)
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

    private static func makeHelperConfiguration(_ configuration: NulConnectTunnelLaunchConfiguration) -> NulConnectTunHelperConfiguration {
        NulConnectTunHelperConfiguration(
            proxyURL: "socks5://\(configuration.proxyEndpoint.host):\(configuration.proxyEndpoint.port)",
            tunName: nil,
            dnsStrategy: "virtual",
            dnsAddress: configuration.dnsAddress,
            virtualDNSPool: "198.18.0.0/15",
            bypassCIDRs: configuration.bypassCIDRs,
            managedRouteCIDRs: configuration.managedRouteCIDRs,
            managedDomains: configuration.managedDomains,
            mtu: configuration.mtu,
            tcpTimeoutSeconds: 600,
            udpTimeoutSeconds: 30,
            maxSessions: 512,
            setupRoutes: configuration.setupRoutes,
            ipv6Enabled: false,
            packetInformation: true,
            exitOnFatalError: false,
            verbosity: "debug"
        )
    }

    private static func preferredDNSServer(resource: ATRResourceSnapshot) async -> String {
        if let dnsServer = normalizedDNSServer(resource.dnsServer) {
            return dnsServer
        }
        let systemServers = await systemDNSServers()
        if let server = systemServers.first {
            return server
        }
        return "1.1.1.1"
    }

    private static func normalizedDNSServer(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.contains(":") {
            // tun2proxy is currently launched without IPv6 support.
            return nil
        }
        return trimmed
    }

    private static func systemDNSServers() async -> [String] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--dns"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return []
            }
            guard process.terminationStatus == 0 else {
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            var servers: [String] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let range = trimmed.range(of: "nameserver[") else {
                    continue
                }
                let suffix = trimmed[range.upperBound...]
                guard let colon = suffix.firstIndex(of: ":") else {
                    continue
                }
                let server = suffix[suffix.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if server.contains(":") || server.isEmpty {
                    continue
                }
                servers.append(server)
            }
            var seen = Set<String>()
            return servers.filter { seen.insert($0).inserted }
        }.value
    }

    private static func makeBypassCIDRs(resource: ATRResourceSnapshot, serverHost: String) async -> [String] {
        var cidrs = [
            "127.0.0.0/8",
            "169.254.0.0/16",
            "224.0.0.0/4",
            "255.255.255.255/32"
        ]
        cidrs.append(contentsOf: resource.excludedIPs.compactMap(ipv4HostCIDR))
        cidrs.append(contentsOf: resource.nodeGroups.flatMap(\.addresses).compactMap(ipv4CIDRFromHostPort))
        if let dnsServer = normalizedDNSServer(resource.dnsServer),
           let dnsCIDR = ipv4HostCIDR(dnsServer) {
            cidrs.append(dnsCIDR)
        }
        cidrs.append(contentsOf: await ipv4CIDRsForHost(serverHost))
        var seen = Set<String>()
        return cidrs.filter { seen.insert($0).inserted }
    }

    private static func makeManagedRouteCIDRs(resource: ATRResourceSnapshot) -> [String] {
        var cidrs = ["198.18.0.0/15"]
        for item in resource.ipResources {
            cidrs.append(contentsOf: ipv4RangeCIDRs(ipMin: item.ipMin, ipMax: item.ipMax))
        }
        var seen = Set<String>()
        return cidrs.filter { seen.insert($0).inserted }
    }

    private static func makeManagedDomains(resource: ATRResourceSnapshot) -> [String] {
        var domains = resource.domainResources.map(\.domain)
        domains.append(contentsOf: resource.dnsResources.map(\.domain))
        var seen = Set<String>()
        return domains
            .map(normalizedResolverDomain)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedResolverDomain(_ value: String) -> String {
        var domain = value
            .trimmingCharacters(in: CharacterSet(charactersIn: ". \n\r\t"))
            .lowercased()
        if domain.hasPrefix("*.") {
            domain.removeFirst(2)
        }
        return domain
    }

    private static func ipv4RangeCIDRs(ipMin: String, ipMax: String) -> [String] {
        guard let rangeStart = ipv4UInt32(ipMin),
              let rangeEnd = ipv4UInt32(ipMax),
              rangeStart <= rangeEnd else {
            return [ipMin, ipMax].compactMap(ipv4HostCIDR)
        }

        var output: [String] = []
        var start = rangeStart
        while start <= rangeEnd {
            let remaining = UInt64(rangeEnd) - UInt64(start) + 1
            let alignmentSize = start == 0 ? UInt64(1) << 32 : UInt64(start & (~start &+ 1))
            var blockSize = Swift.min(alignmentSize, UInt64(1) << 32)
            while blockSize > remaining {
                blockSize >>= 1
            }
            let prefix = 32 - Int(blockSize.trailingZeroBitCount)
            output.append("\(ipv4String(start))/\(prefix)")
            if UInt64(start) + blockSize > UInt64(UInt32.max) {
                break
            }
            start = UInt32(UInt64(start) + blockSize)
        }
        return output
    }

    private static func ipv4UInt32(_ value: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else {
            return nil
        }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv4String(_ value: UInt32) -> String {
        let a = (value >> 24) & 0xff
        let b = (value >> 16) & 0xff
        let c = (value >> 8) & 0xff
        let d = value & 0xff
        return "\(a).\(b).\(c).\(d)"
    }

    private static func ipv4CIDRFromHostPort(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let direct = ipv4HostCIDR(trimmed) {
            return direct
        }
        if trimmed.first == "[" {
            return nil
        }
        let host = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        return ipv4HostCIDR(host)
    }

    private static func ipv4CIDRsForHost(_ value: String) async -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        if let cidr = ipv4HostCIDR(trimmed) {
            return [cidr]
        }

        return await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_INET,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(trimmed, nil, &hints, &result) == 0, let result else {
                return []
            }
            defer { freeaddrinfo(result) }

            var output: [String] = []
            var cursor: UnsafeMutablePointer<addrinfo>? = result
            while let current = cursor {
                defer { cursor = current.pointee.ai_next }
                guard current.pointee.ai_family == AF_INET,
                      let sockaddr = current.pointee.ai_addr else {
                    continue
                }
                let addr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var copy = addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    continue
                }
                output.append("\(String(cString: buffer))/32")
            }

            var seen = Set<String>()
            return output.filter { seen.insert($0).inserted }
        }.value
    }

    private static func ipv4HostCIDR(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.split(separator: ".").count == 4 else {
            return nil
        }
        var address = in_addr()
        guard inet_pton(AF_INET, trimmed, &address) == 1 else {
            return nil
        }
        return "\(trimmed)/32"
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
