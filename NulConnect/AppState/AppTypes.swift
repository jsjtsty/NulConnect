import Combine
import Foundation

enum NulConnectLocalization {
    nonisolated static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    nonisolated static func format(_ key: String, _ arguments: [CVarArg]) -> String {
        String(format: text(key), arguments: arguments)
    }
}

enum NulConnectRouteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case proxy
    case tun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxy: return NulConnectLocalization.text("Proxy Mode")
        case .tun: return NulConnectLocalization.text("VPN Mode")
        }
    }

    var subtitle: String {
        switch self {
        case .proxy: return NulConnectLocalization.text("System proxy stays unchanged by default and can be enabled when needed")
        case .tun: return NulConnectLocalization.text("Route traffic through a virtual network interface")
        }
    }
}

enum NulConnectConnectionPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disconnected: return NulConnectLocalization.text("Disconnected")
        case .connecting: return NulConnectLocalization.text("Connecting")
        case .connected: return NulConnectLocalization.text("Connected")
        case .disconnecting: return NulConnectLocalization.text("Disconnecting")
        case .failed: return NulConnectLocalization.text("Failed")
        }
    }
}

struct NulConnectConnectionState: Codable, Sendable, Equatable {
    var phase: NulConnectConnectionPhase
    var message: String?
    var updatedAt: Date
}

struct NulConnectProfile: Codable, Sendable, Equatable {
    var serverHost: String
    var serverPort: UInt16
    var localProxyPort: UInt16
    var loginDomain: String
    var preferredAuthType: String?
    var userAgent: String
    var allowInsecureTLS: Bool
    var routeMode: NulConnectRouteMode
    var useSystemProxy: Bool
    var connectTimeoutMillis: UInt64
    var ioTimeoutMillis: UInt64
    var nodeProbeTimeoutMillis: UInt64
    var clientType: String
    var platform: String

    static let `default` = NulConnectProfile(
        serverHost: "",
        serverPort: 443,
        localProxyPort: 1920,
        loginDomain: "",
        preferredAuthType: nil,
        userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) aTrustTray/2.4.10.50 Chrome/83.0.4103.94 Electron/9.0.2 Safari/537.36 aTrustTray-Linux-Plat-Ubuntu-x64 SPCClientType",
        allowInsecureTLS: false,
        routeMode: .proxy,
        useSystemProxy: false,
        connectTimeoutMillis: 15_000,
        ioTimeoutMillis: 10_000,
        nodeProbeTimeoutMillis: 5_000,
        clientType: "SDPClient",
        platform: "Linux"
    )

    enum CodingKeys: String, CodingKey {
        case serverHost
        case serverPort
        case localProxyPort
        case loginDomain
        case preferredAuthType
        case userAgent
        case allowInsecureTLS
        case routeMode
        case useSystemProxy
        case connectTimeoutMillis
        case ioTimeoutMillis
        case nodeProbeTimeoutMillis
        case clientType
        case platform
    }

    init(
        serverHost: String,
        serverPort: UInt16,
        localProxyPort: UInt16,
        loginDomain: String,
        preferredAuthType: String?,
        userAgent: String,
        allowInsecureTLS: Bool,
        routeMode: NulConnectRouteMode,
        useSystemProxy: Bool,
        connectTimeoutMillis: UInt64,
        ioTimeoutMillis: UInt64,
        nodeProbeTimeoutMillis: UInt64,
        clientType: String,
        platform: String
    ) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.localProxyPort = localProxyPort
        self.loginDomain = loginDomain
        self.preferredAuthType = preferredAuthType
        self.userAgent = userAgent
        self.allowInsecureTLS = allowInsecureTLS
        self.routeMode = routeMode
        self.useSystemProxy = useSystemProxy
        self.connectTimeoutMillis = connectTimeoutMillis
        self.ioTimeoutMillis = ioTimeoutMillis
        self.nodeProbeTimeoutMillis = nodeProbeTimeoutMillis
        self.clientType = clientType
        self.platform = platform
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverHost = try container.decode(String.self, forKey: .serverHost)
        self.serverPort = try container.decode(UInt16.self, forKey: .serverPort)
        self.localProxyPort = try container.decodeIfPresent(UInt16.self, forKey: .localProxyPort) ?? Self.default.localProxyPort
        self.loginDomain = try container.decode(String.self, forKey: .loginDomain)
        self.preferredAuthType = try container.decodeIfPresent(String.self, forKey: .preferredAuthType)
        self.userAgent = try container.decode(String.self, forKey: .userAgent)
        self.allowInsecureTLS = try container.decode(Bool.self, forKey: .allowInsecureTLS)
        self.routeMode = try container.decode(NulConnectRouteMode.self, forKey: .routeMode)
        self.useSystemProxy = try container.decode(Bool.self, forKey: .useSystemProxy)
        self.connectTimeoutMillis = try container.decode(UInt64.self, forKey: .connectTimeoutMillis)
        self.ioTimeoutMillis = try container.decode(UInt64.self, forKey: .ioTimeoutMillis)
        self.nodeProbeTimeoutMillis = try container.decode(UInt64.self, forKey: .nodeProbeTimeoutMillis)
        self.clientType = try container.decode(String.self, forKey: .clientType)
        self.platform = try container.decode(String.self, forKey: .platform)
    }

}

struct NulConnectSessionSummary: Codable, Sendable, Equatable {
    var username: String
    var deviceID: String
    var cookieCount: Int
    var savedAt: Date

    init(material: ATRSessionMaterial, savedAt: Date = .now) {
        self.username = material.username
        self.deviceID = material.deviceID
        self.cookieCount = material.cookies.count
        self.savedAt = savedAt
    }
}

struct NulConnectProxyEndpoint: Sendable, Codable, Equatable {
    var host: String
    var port: UInt16

    var displayString: String {
        "\(host):\(port)"
    }
}

nonisolated struct NulConnectTrafficCounters: Sendable, Equatable {
    var uploadedBytes: UInt64
    var downloadedBytes: UInt64
    var uploadedPackets: UInt64
    var downloadedPackets: UInt64

    static let zero = NulConnectTrafficCounters(
        uploadedBytes: 0,
        downloadedBytes: 0,
        uploadedPackets: 0,
        downloadedPackets: 0
    )
}

nonisolated struct NulConnectTrafficStatistics: Sendable, Equatable {
    var counters: NulConnectTrafficCounters
    var uploadBytesPerSecond: Double
    var downloadBytesPerSecond: Double
    var connectionStartedAt: Date?
    var connectionDuration: TimeInterval
    var isLive: Bool

    static let empty = NulConnectTrafficStatistics(
        counters: .zero,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
        connectionStartedAt: nil,
        connectionDuration: 0,
        isLive: false
    )
}

@MainActor
final class NulConnectTrafficStore: ObservableObject {
    @Published fileprivate(set) var statistics: NulConnectTrafficStatistics = .empty

    func update(_ statistics: NulConnectTrafficStatistics) {
        self.statistics = statistics
    }
}

enum NulConnectProxyRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running(endpoint: NulConnectProxyEndpoint)
    case stopping
    case failed(message: String)
}

enum NulConnectSystemProxyRuntimeState: Equatable, Sendable {
    case disabled
    case enabling
    case enabled(endpoint: NulConnectProxyEndpoint)
    case disabling
    case failed(message: String)
}

enum NulConnectTunnelRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    /// The connection dropped (network loss, sleep, network switch) and is
    /// being re-established automatically.
    case reconnecting(attempt: Int)
    case failed(message: String)
}

enum NulConnectLoginState: Equatable, Sendable {
    case idle
    case loadingMethods
    case ready(methodCount: Int)
    case presenting(methodName: String)
    case finalizing
    case failed(message: String)
    case succeeded(message: String)

    var title: String {
        switch self {
        case .idle: return NulConnectLocalization.text("Not started")
        case .loadingMethods: return NulConnectLocalization.text("Loading sign-in methods")
        case .ready(let methodCount): return String(format: NulConnectLocalization.text("Loaded %1$@ sign-in methods"), String(methodCount))
        case .presenting(let methodName): return "\(NulConnectLocalization.text("Opening")) \(methodName)"
        case .finalizing: return NulConnectLocalization.text("Completing sign-in")
        case .failed: return NulConnectLocalization.text("Sign-in failed")
        case .succeeded: return NulConnectLocalization.text("Signed in")
        }
    }

    var detail: String? {
        switch self {
        case .failed(let message), .succeeded(let message):
            return message
        default:
            return nil
        }
    }
}

enum NulConnectHelperActivityState: Equatable, Sendable {
    case idle
    case checking
    case installing(message: String)
    case waitingForStart(message: String)
    case succeeded(message: String)
    case failed(message: String)

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .checking:
            return NulConnectLocalization.text("Checking privileged component")
        case .installing(let message),
             .waitingForStart(let message),
             .succeeded(let message),
             .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .installing, .waitingForStart:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }
}

struct NulConnectWebLoginSession: Identifiable, Sendable {
    let id: UUID
    let method: ATRAuthMethod
    let deviceID: String
    let title: String
    let subtitle: String
    let startURL: URL
    let captureHint: String
    let capturePolicy: NulConnectWebLoginCapturePolicy
}

enum NulConnectWebLoginCapturePolicy: Sendable {
    case cas(baseHost: String, allowedHosts: Set<String>)
    case httpsOauth2(baseHost: String, allowedHosts: Set<String>)

    nonisolated var hint: String {
        switch self {
        case .cas:
            return NulConnectLocalization.text("Capture CAS callback containing a ticket")
        case .httpsOauth2:
            return NulConnectLocalization.text("Capture OAuth2 callback containing a code")
        }
    }

    nonisolated func shouldCapture(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        let queryItems = components.queryItems ?? []
        switch self {
        case .cas:
            return queryItems.contains(where: { $0.name == "ticket" && !($0.value ?? "").isEmpty })
        case .httpsOauth2:
            return queryItems.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty })
        }
    }

    nonisolated func validate(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("Could not parse callback URL"))
        }

        switch self {
        case .cas(let baseHost, let allowedHosts):
            guard let host = components.host else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("CAS callback is missing a host name"))
            }
            guard allowedHosts.contains(Self.normalizedHost(host)) else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("CAS callback host does not match"))
            }
            guard components.path.contains("cas") else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("CAS callback path does not match"))
            }
            let ticket = components.queryItems?.first(where: { $0.name == "ticket" && !($0.value ?? "").isEmpty })
            guard ticket != nil else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("CAS callback is missing a ticket"))
            }
            if components.scheme == "https" {
                components.host = baseHost
                return components.url ?? url
            }
            if components.scheme == "http" {
                components.scheme = "https"
                components.host = baseHost
                return components.url ?? url
            }
            throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("CAS callback uses an invalid scheme"))
        case .httpsOauth2(_, let allowedHosts):
            guard components.scheme == "https" else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("OAuth2 callback must use HTTPS"))
            }
            guard let host = components.host,
                  allowedHosts.contains(Self.normalizedHost(host)) else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("OAuth2 callback host does not match"))
            }
            guard components.path == "/passport/v1/auth/httpsOauth2" else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("OAuth2 callback path does not match"))
            }
            let code = components.queryItems?.first(where: { $0.name == "code" && !($0.value ?? "").isEmpty })
            guard code != nil else {
                throw NulConnectLoginError.invalidCallbackURL(NulConnectLocalization.text("OAuth2 callback is missing a code"))
            }
            return components.url ?? url
        }
    }

    nonisolated static func make(
        authType: String,
        baseHost: String,
        loginURL: String,
        additionalHost: String? = nil
    ) -> NulConnectWebLoginCapturePolicy? {
        let normalizedBaseHost = normalizedHost(baseHost)
        guard !normalizedBaseHost.isEmpty else {
            return nil
        }

        var allowedHosts = Set([normalizedBaseHost])
        if let loginHost = URL(string: loginURL)?.host {
            allowedHosts.insert(normalizedHost(loginHost))
        }
        if let additionalHost {
            allowedHosts.insert(normalizedHost(additionalHost))
        }

        switch authType {
        case "auth/cas":
            return .cas(baseHost: normalizedBaseHost, allowedHosts: allowedHosts)
        case "auth/httpsOauth2":
            return .httpsOauth2(baseHost: normalizedBaseHost, allowedHosts: allowedHosts)
        default:
            return nil
        }
    }

    private nonisolated static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\r\t")).lowercased()
    }
}

enum NulConnectLoginError: LocalizedError, Equatable {
    case unsupportedAuthType(String)
    case noWebLoginMethods
    case noSession
    case invalidCallbackURL(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAuthType(let value):
            return NulConnectLocalization.format("Unsupported WebView sign-in type: %1$@", [String(describing: value)])
        case .noWebLoginMethods:
            return NulConnectLocalization.text("No supported WebView sign-in method found")
        case .noSession:
            return NulConnectLocalization.text("Sign-in session has not been initialized")
        case .invalidCallbackURL(let message):
            return message
        case .failed(let message):
            return message
        }
    }
}
