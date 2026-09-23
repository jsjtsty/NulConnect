import Foundation
import Darwin

nonisolated enum NulConnectTunnelManagerError: LocalizedError {
    case helperStateUnavailable
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperStateUnavailable:
            return NulConnectLocalization.text("Could not read VPN runtime status")
        case .helperFailed(let message):
            return NulConnectLocalization.format("VPN privileged component failed: %1$@", [String(describing: message)])
        }
    }
}

nonisolated struct NulConnectTunnelRuntimeStatus: Sendable {
    var status: String
    var message: String?
    var traffic: NulConnectTrafficCounters
}

nonisolated final class NulConnectTunnelManager: @unchecked Sendable {
    private let helperClient = NulConnectHelperClient()

    init(baseDirectory: URL? = nil) throws {
        _ = baseDirectory
    }

    func start(
        configuration: NulConnectTunnelLaunchConfiguration,
        helperActivityReporter: NulConnectHelperClient.ActivityReporter? = nil
    ) async throws {
        NulConnectDiagnostics.log("[NulConnect][Tunnel] start: server=\(configuration.clientConfiguration.serverHost):\(configuration.clientConfiguration.serverPort), dns=\(configuration.dnsAddress), mtu=\(configuration.mtu), setupRoutes=\(configuration.setupRoutes), managedRoutes=\(configuration.managedRouteCIDRs.count) [\(configuration.managedRouteCIDRs.prefix(12).joined(separator: ", "))]")
        try await helperClient.ensureInstalledOrUpToDate(reporter: helperActivityReporter)
        let helperConfiguration = Self.makeHelperConfiguration(configuration)
        NulConnectDiagnostics.log("[NulConnect][Tunnel] start: helper config server=\(helperConfiguration.client.serverHost):\(helperConfiguration.client.serverPort) dns=\(helperConfiguration.dnsAddress) setupRoutes=\(helperConfiguration.setupRoutes) mtu=\(helperConfiguration.mtu)")
        let response = try await helperClient.startTun(configuration: helperConfiguration)
        NulConnectDiagnostics.log("[NulConnect][Tunnel] start: helper response=\(response)")
        try await waitForPersistentHelperRunning()
        NulConnectDiagnostics.log("[NulConnect][Tunnel] start via helper: success")
    }

    func stop() async throws {
        NulConnectDiagnostics.log("[NulConnect][Tunnel] stop: starting")
        guard helperClient.isInstalled() else {
            throw NulConnectHelperClientError.helperNotInstalled
        }
        try await helperClient.stopTun()
        NulConnectDiagnostics.log("[NulConnect][Tunnel] stop via helper: success")
    }

    func cleanupPrivilegedState() async throws {
        if helperClient.isRunning() {
            try await helperClient.cleanup()
        } else {
            NulConnectDiagnostics.log("[NulConnect][Tunnel] cleanupPrivilegedState: helper socket missing, skipping helper cleanup")
        }
    }

    func runtimeStatus() async throws -> NulConnectTunnelRuntimeStatus? {
        guard helperClient.isRunning() else {
            return NulConnectTunnelRuntimeStatus(
                status: "failed",
                message: NulConnectLocalization.text("VPN privileged component exited"),
                traffic: .zero
            )
        }
        let response = try await helperClient.status()
        guard let tun = response["tun"] as? [String: Any],
              let status = tun["status"] as? String else {
            throw NulConnectTunnelManagerError.helperStateUnavailable
        }
        return NulConnectTunnelRuntimeStatus(
            status: status,
            message: tun["message"] as? String,
            traffic: NulConnectTrafficCounters(
                uploadedBytes: Self.uint64Value(tun["upload_bytes"]),
                downloadedBytes: Self.uint64Value(tun["download_bytes"]),
                uploadedPackets: Self.uint64Value(tun["upload_packets"]),
                downloadedPackets: Self.uint64Value(tun["download_packets"])
            )
        )
    }

    private static func uint64Value(_ value: Any?) -> UInt64 {
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        if let value = value as? UInt64 {
            return value
        }
        return 0
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
        profile: ATRClientConfiguration,
        session: ATRSessionMaterial,
        resource: ATRResourceSnapshot,
        serverHost: String
    ) async -> NulConnectTunnelLaunchConfiguration {
        let dnsAddress = await preferredDNSServer(resource: resource)
        return NulConnectTunnelLaunchConfiguration(
            clientConfiguration: profile,
            session: session,
            resourceBytes: resource.resourceBytes,
            serviceHost: serverHost,
            dnsAddress: dnsAddress,
            managedRouteCIDRs: makeManagedRouteCIDRs(resource: resource),
            managedDomains: makeManagedDomains(resource: resource),
            setupRoutes: true
        )
    }

    private static func makeHelperConfiguration(_ configuration: NulConnectTunnelLaunchConfiguration) -> NulConnectTunHelperConfiguration {
        NulConnectTunHelperConfiguration(
            client: NulConnectTunHelperClientConfiguration(
                serverHost: configuration.clientConfiguration.serverHost,
                serverPort: configuration.clientConfiguration.serverPort,
                userAgent: configuration.clientConfiguration.userAgent,
                connectTimeoutMilliseconds: configuration.clientConfiguration.connectTimeout,
                ioTimeoutMilliseconds: configuration.clientConfiguration.ioTimeout,
                nodeProbeTimeoutMilliseconds: configuration.clientConfiguration.nodeProbeTimeout,
                allowInsecureTLS: configuration.clientConfiguration.allowInsecureTLS
            ),
            session: NulConnectTunHelperSessionMaterial(
                username: configuration.session.username,
                sid: configuration.session.sid,
                deviceID: configuration.session.deviceID,
                connectionID: configuration.session.connectionID,
                signKeyHex: configuration.session.signKeyHex,
                cookies: configuration.session.cookies
            ),
            resourceBytes: configuration.resourceBytes,
            serviceHost: configuration.serviceHost,
            tunName: nil,
            dnsAddress: configuration.dnsAddress,
            managedRouteCIDRs: configuration.managedRouteCIDRs,
            managedDomains: configuration.managedDomains,
            mtu: configuration.mtu,
            setupRoutes: configuration.setupRoutes,
            exitOnFatalError: true
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
