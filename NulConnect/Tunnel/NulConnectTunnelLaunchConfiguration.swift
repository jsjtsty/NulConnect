import Foundation

nonisolated struct NulConnectTunnelLaunchConfiguration: Codable, Sendable {
    var clientConfiguration: ATRClientConfiguration
    var session: ATRSessionMaterial
    var resourceBytes: Data
    var serviceHost: String
    var dnsAddress: String
    var managedRouteCIDRs: [String]
    var managedDomains: [String]
    var mtu: UInt16
    var setupRoutes: Bool
    var savedAt: Date

    init(
        clientConfiguration: ATRClientConfiguration,
        session: ATRSessionMaterial,
        resourceBytes: Data,
        serviceHost: String,
        dnsAddress: String,
        managedRouteCIDRs: [String] = [],
        managedDomains: [String] = [],
        mtu: UInt16 = 1400,
        setupRoutes: Bool = true,
        savedAt: Date = .now
    ) {
        self.clientConfiguration = clientConfiguration
        self.session = session
        self.resourceBytes = resourceBytes
        self.serviceHost = serviceHost
        self.dnsAddress = dnsAddress
        self.managedRouteCIDRs = managedRouteCIDRs
        self.managedDomains = managedDomains
        self.mtu = mtu
        self.setupRoutes = setupRoutes
        self.savedAt = savedAt
    }
}

nonisolated struct NulConnectTunHelperConfiguration: Codable, Sendable {
    var client: NulConnectTunHelperClientConfiguration
    var session: NulConnectTunHelperSessionMaterial
    var resourceBytes: Data
    var serviceHost: String
    var tunName: String?
    var dnsAddress: String
    var managedRouteCIDRs: [String]
    var managedDomains: [String]
    var mtu: UInt16
    var setupRoutes: Bool
    var exitOnFatalError: Bool

    enum CodingKeys: String, CodingKey {
        case client
        case session
        case resourceBytes = "resource_bytes"
        case serviceHost = "service_host"
        case tunName = "tun_name"
        case dnsAddress = "dns_addr"
        case managedRouteCIDRs = "managed_route_cidrs"
        case managedDomains = "managed_domains"
        case mtu
        case setupRoutes = "setup_routes"
        case exitOnFatalError = "exit_on_fatal_error"
    }
}

nonisolated struct NulConnectTunHelperClientConfiguration: Codable, Sendable {
    var serverHost: String
    var serverPort: UInt16
    var userAgent: String
    var connectTimeoutMilliseconds: UInt64
    var ioTimeoutMilliseconds: UInt64
    var nodeProbeTimeoutMilliseconds: UInt64
    var allowInsecureTLS: Bool

    enum CodingKeys: String, CodingKey {
        case serverHost = "server_host"
        case serverPort = "server_port"
        case userAgent = "user_agent"
        case connectTimeoutMilliseconds = "connect_timeout_ms"
        case ioTimeoutMilliseconds = "io_timeout_ms"
        case nodeProbeTimeoutMilliseconds = "node_probe_timeout_ms"
        case allowInsecureTLS = "allow_insecure_tls"
    }
}

nonisolated struct NulConnectTunHelperSessionMaterial: Codable, Sendable {
    var username: String
    var sid: String
    var deviceID: String
    var connectionID: String
    var signKeyHex: String
    var cookies: [ATRCookie]

    enum CodingKeys: String, CodingKey {
        case username
        case sid
        case deviceID = "device_id"
        case connectionID = "connection_id"
        case signKeyHex = "sign_key_hex"
        case cookies
    }
}

nonisolated struct NulConnectTunHelperState: Codable, Sendable {
    var pid: Int32
    var status: String
    var message: String?
    var updatedAtUnixSeconds: UInt64
    var sessions: Int?

    enum CodingKeys: String, CodingKey {
        case pid
        case status
        case message
        case updatedAtUnixSeconds = "updated_at_unix_secs"
        case sessions
    }
}
