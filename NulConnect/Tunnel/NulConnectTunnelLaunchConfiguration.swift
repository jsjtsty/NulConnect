import Foundation

nonisolated struct NulConnectTunnelLaunchConfiguration: Codable, Sendable {
    var proxyEndpoint: NulConnectProxyEndpoint
    var dnsAddress: String
    var bypassCIDRs: [String]
    var managedRouteCIDRs: [String]
    var managedDomains: [String]
    var mtu: UInt16
    var setupRoutes: Bool
    var savedAt: Date

    init(
        proxyEndpoint: NulConnectProxyEndpoint,
        dnsAddress: String,
        bypassCIDRs: [String] = [],
        managedRouteCIDRs: [String] = [],
        managedDomains: [String] = [],
        mtu: UInt16 = 1400,
        setupRoutes: Bool = true,
        savedAt: Date = .now
    ) {
        self.proxyEndpoint = proxyEndpoint
        self.dnsAddress = dnsAddress
        self.bypassCIDRs = bypassCIDRs
        self.managedRouteCIDRs = managedRouteCIDRs
        self.managedDomains = managedDomains
        self.mtu = mtu
        self.setupRoutes = setupRoutes
        self.savedAt = savedAt
    }
}

nonisolated struct NulConnectTunHelperConfiguration: Codable, Sendable {
    var proxyURL: String
    var tunName: String?
    var dnsStrategy: String
    var dnsAddress: String
    var virtualDNSPool: String
    var bypassCIDRs: [String]
    var managedRouteCIDRs: [String]
    var managedDomains: [String]
    var mtu: UInt16
    var tcpTimeoutSeconds: UInt64
    var udpTimeoutSeconds: UInt64
    var maxSessions: Int
    var setupRoutes: Bool
    var ipv6Enabled: Bool
    var packetInformation: Bool
    var exitOnFatalError: Bool
    var verbosity: String

    enum CodingKeys: String, CodingKey {
        case proxyURL = "proxy_url"
        case tunName = "tun_name"
        case dnsStrategy = "dns_strategy"
        case dnsAddress = "dns_addr"
        case virtualDNSPool = "virtual_dns_pool"
        case bypassCIDRs = "bypass_cidrs"
        case managedRouteCIDRs = "managed_route_cidrs"
        case managedDomains = "managed_domains"
        case mtu
        case tcpTimeoutSeconds = "tcp_timeout_secs"
        case udpTimeoutSeconds = "udp_timeout_secs"
        case maxSessions = "max_sessions"
        case setupRoutes = "setup_routes"
        case ipv6Enabled = "ipv6_enabled"
        case packetInformation = "packet_information"
        case exitOnFatalError = "exit_on_fatal_error"
        case verbosity
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
