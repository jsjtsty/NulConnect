import Foundation

enum NulConnectRouteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case proxy
    case tun

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxy: return "代理模式"
        case .tun: return "TUN 模式"
        }
    }

    var subtitle: String {
        switch self {
        case .proxy: return "默认不改系统代理，可按需启用"
        case .tun: return "由虚拟网卡接管流量"
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
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .disconnecting: return "断开中"
        case .failed: return "失败"
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

    func normalizedForHITAuth() -> NulConnectProfile {
        var copy = self
        if copy.localProxyPort == 0 {
            copy.localProxyPort = Self.default.localProxyPort
        }
        if copy.clientType == "desktop" || copy.clientType.isEmpty {
            copy.clientType = "SDPClient"
        }
        if copy.platform == "macOS" || copy.platform.isEmpty {
            copy.platform = "Linux"
        }
        if copy.userAgent == "NulConnect/1.0" || copy.userAgent.isEmpty {
            copy.userAgent = Self.default.userAgent
        }
        return copy
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
        case .idle: return "未开始"
        case .loadingMethods: return "正在获取登录方式"
        case .ready(let methodCount): return "已获取 \(methodCount) 个登录方式"
        case .presenting(let methodName): return "正在打开 \(methodName)"
        case .finalizing: return "正在完成登录"
        case .failed: return "登录失败"
        case .succeeded: return "登录成功"
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
            return "正在检查特权组件"
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
    case cas(baseHost: String)
    case httpsOauth2(baseHost: String)

    nonisolated var hint: String {
        switch self {
        case .cas:
            return "捕获包含 ticket 的 CAS 回调"
        case .httpsOauth2:
            return "捕获包含 code 的 OAuth2 回调"
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
            throw NulConnectLoginError.invalidCallbackURL("无法解析回调地址")
        }

        switch self {
        case .cas(let baseHost):
            guard let host = components.host else {
                throw NulConnectLoginError.invalidCallbackURL("CAS 回调缺少主机名")
            }
            let allowedHosts = [baseHost, "ids-hit-edu-cn-s.ivpn.hit.edu.cn"]
            guard allowedHosts.contains(host) else {
                throw NulConnectLoginError.invalidCallbackURL("CAS 回调主机不匹配")
            }
            guard components.path.contains("cas") else {
                throw NulConnectLoginError.invalidCallbackURL("CAS 回调路径不匹配")
            }
            let ticket = components.queryItems?.first(where: { $0.name == "ticket" && !($0.value ?? "").isEmpty })
            guard ticket != nil else {
                throw NulConnectLoginError.invalidCallbackURL("CAS 回调缺少 ticket")
            }
            if components.scheme == "https" {
                components.host = baseHost
                return components.url ?? url
            }
            if components.scheme == "http" && baseHost == "ivpn.hit.edu.cn" {
                components.scheme = "https"
                components.host = baseHost
                return components.url ?? url
            }
            throw NulConnectLoginError.invalidCallbackURL("CAS 回调协议不正确")
        case .httpsOauth2(let baseHost):
            guard components.scheme == "https" else {
                throw NulConnectLoginError.invalidCallbackURL("OAuth2 回调必须是 HTTPS")
            }
            guard components.host == baseHost else {
                throw NulConnectLoginError.invalidCallbackURL("OAuth2 回调主机不匹配")
            }
            guard components.path == "/passport/v1/auth/httpsOauth2" else {
                throw NulConnectLoginError.invalidCallbackURL("OAuth2 回调路径不匹配")
            }
            let code = components.queryItems?.first(where: { $0.name == "code" && !($0.value ?? "").isEmpty })
            guard code != nil else {
                throw NulConnectLoginError.invalidCallbackURL("OAuth2 回调缺少 code")
            }
            return components.url ?? url
        }
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
            return "暂不支持的 WebView 登录类型: \(value)"
        case .noWebLoginMethods:
            return "未找到可用的 HIT WebView 登录方式"
        case .noSession:
            return "登录会话尚未初始化"
        case .invalidCallbackURL(let message):
            return message
        case .failed(let message):
            return message
        }
    }
}
