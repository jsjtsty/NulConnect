import Foundation
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profile: NulConnectProfile {
        didSet {
            scheduleProfilePersistence()
        }
    }

    @Published private(set) var connectionState: NulConnectConnectionState
    @Published private(set) var proxyState: NulConnectProxyRuntimeState = .stopped
    @Published private(set) var loginState: NulConnectLoginState = .idle
    @Published private(set) var availableLoginMethods: [ATRAuthMethod] = []
    @Published var webLoginSession: NulConnectWebLoginSession?
    @Published private(set) var sessionSummary: NulConnectSessionSummary?
    @Published private(set) var resourceSnapshot: ATRResourceSnapshot?
    @Published private(set) var bannerMessage: String?
    @Published private(set) var lastPersistenceErrorMessage: String?

    private let authEngine = NulConnectAuthEngine()
    private let profileStore: ProfileStore
    private let sessionVault: SessionVault
    private let resourceStore: ResourceSnapshotStore
    private var profilePersistenceTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var proxyService: NulConnectProxyService?
    private var proxyTask: Task<Void, Never>?
    private var storedSessionMaterial: ATRSessionMaterial?
    private var suppressProfilePersistence = false

    init(
        profileStore: ProfileStore,
        sessionVault: SessionVault,
        resourceStore: ResourceSnapshotStore,
        profile: NulConnectProfile,
        connectionState: NulConnectConnectionState = NulConnectConnectionState(
            phase: .disconnected,
            message: nil,
            updatedAt: .now
        ),
        sessionSummary: NulConnectSessionSummary? = nil,
        resourceSnapshot: ATRResourceSnapshot? = nil,
        bannerMessage: String? = nil,
        storedSessionMaterial: ATRSessionMaterial? = nil
    ) {
        self.profileStore = profileStore
        self.sessionVault = sessionVault
        self.resourceStore = resourceStore
        self.profile = profile
        self.connectionState = connectionState
        self.proxyState = .stopped
        self.sessionSummary = sessionSummary
        self.resourceSnapshot = resourceSnapshot
        self.bannerMessage = bannerMessage
        self.storedSessionMaterial = storedSessionMaterial
    }

    static func bootstrap() -> AppModel {
        do {
            let profileStore = try ProfileStore()
            let sessionVault = try SessionVault()
            let resourceStore = try ResourceSnapshotStore()
            let loadedProfile = try profileStore.load()
            let profile = loadedProfile.normalizedForHITAuth()
            if profile != loadedProfile {
                try profileStore.save(profile)
            }
            let sessionMaterial = try sessionVault.load()
            let sessionSummary = try sessionVault.loadSummary() ?? sessionMaterial.map { NulConnectSessionSummary(material: $0) }
            if sessionSummary == nil, let sessionMaterial {
                try sessionVault.save(sessionMaterial)
            }
            let resourceSnapshot = try resourceStore.load()
            return AppModel(
                profileStore: profileStore,
                sessionVault: sessionVault,
                resourceStore: resourceStore,
                profile: profile,
                sessionSummary: sessionSummary,
                resourceSnapshot: resourceSnapshot,
                storedSessionMaterial: sessionMaterial
            )
        } catch {
            do {
                let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NulConnect", isDirectory: true)
                let profileStore = try ProfileStore(baseDirectory: fallbackRoot)
                let sessionVault = try SessionVault(baseDirectory: fallbackRoot)
                let resourceStore = try ResourceSnapshotStore(baseDirectory: fallbackRoot)
                let loadedProfile = (try? profileStore.load()) ?? .default
                let profile = loadedProfile.normalizedForHITAuth()
                if profile != loadedProfile {
                    try? profileStore.save(profile)
                }
                let sessionMaterial = try? sessionVault.load()
                let sessionSummary = (try? sessionVault.loadSummary()) ?? sessionMaterial.map { NulConnectSessionSummary(material: $0) }
                let resourceSnapshot = try? resourceStore.load()
                return AppModel(
                    profileStore: profileStore,
                    sessionVault: sessionVault,
                    resourceStore: resourceStore,
                    profile: profile,
                    sessionSummary: sessionSummary,
                    resourceSnapshot: resourceSnapshot,
                    bannerMessage: "已回退到临时存储: \(error.localizedDescription)",
                    storedSessionMaterial: sessionMaterial
                )
            } catch {
                fatalError("Unable to bootstrap app model: \(error)")
            }
        }
    }

    var effectiveSystemProxyEnabled: Bool {
        profile.routeMode == .proxy && profile.useSystemProxy
    }

    var isLoginConfigurationReady: Bool {
        let host = profile.serverHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !host.isEmpty && host != "localhost" && host != "127.0.0.1"
    }

    var isReadyForProxyMode: Bool {
        storedSessionMaterial != nil && resourceSnapshot != nil
    }

    var needsHITLoginForProxy: Bool {
        !isReadyForProxyMode
    }

    var clientConfiguration: ATRClientConfiguration {
        ATRClientConfiguration(
            serverHost: profile.serverHost,
            serverPort: profile.serverPort,
            userAgent: profile.userAgent,
            connectTimeout: profile.connectTimeoutMillis,
            ioTimeout: profile.ioTimeoutMillis,
            nodeProbeTimeout: profile.nodeProbeTimeoutMillis,
            allowInsecureTLS: profile.allowInsecureTLS
        )
    }

    var authConfiguration: ATRAuthConfiguration {
        ATRAuthConfiguration(
            serverHost: profile.serverHost,
            serverPort: profile.serverPort,
            userAgent: profile.userAgent,
            clientType: profile.clientType,
            platform: profile.platform,
            loginDomain: profile.loginDomain,
            preferredAuthType: profile.preferredAuthType,
            ioTimeout: profile.ioTimeoutMillis,
            allowInsecureTLS: profile.allowInsecureTLS
        )
    }

    func reloadPersistedState() {
        do {
            suppressProfilePersistence = true
            let loadedProfile = try profileStore.load()
            let normalizedProfile = loadedProfile.normalizedForHITAuth()
            profile = normalizedProfile
            if normalizedProfile != loadedProfile {
                try? profileStore.save(normalizedProfile)
            }
            suppressProfilePersistence = false
            let sessionMaterial = try sessionVault.load()
            sessionSummary = try sessionVault.loadSummary() ?? sessionMaterial.map { NulConnectSessionSummary(material: $0) }
            resourceSnapshot = try resourceStore.load()
            storedSessionMaterial = sessionMaterial
            bannerMessage = "已重新载入本地配置"
            lastPersistenceErrorMessage = nil
        } catch {
            suppressProfilePersistence = false
            bannerMessage = "重新载入失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    func saveProfileNow() {
        profilePersistenceTask?.cancel()
        do {
            try profileStore.save(profile)
            lastPersistenceErrorMessage = nil
            bannerMessage = "设置已保存"
        } catch {
            lastPersistenceErrorMessage = error.localizedDescription
            bannerMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    func resetProfileToDefaults() {
        suppressProfilePersistence = true
        profile = .default
        suppressProfilePersistence = false
        saveProfileNow()
    }

    func saveSessionMaterial(_ material: ATRSessionMaterial) {
        do {
            try sessionVault.save(material)
            sessionSummary = NulConnectSessionSummary(material: material)
            storedSessionMaterial = material
            bannerMessage = "会话已保存"
        } catch {
            bannerMessage = "保存会话失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    func clearSessionMaterial() {
        do {
            try sessionVault.clear()
            sessionSummary = nil
            storedSessionMaterial = nil
            bannerMessage = "会话已清除"
        } catch {
            bannerMessage = "清除会话失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    func saveResourceSnapshot(_ snapshot: ATRResourceSnapshot) {
        do {
            try resourceStore.save(snapshot)
            resourceSnapshot = snapshot
            bannerMessage = "资源快照已保存"
        } catch {
            bannerMessage = "保存资源快照失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    func clearResourceSnapshot() {
        do {
            try resourceStore.delete()
            resourceSnapshot = nil
            bannerMessage = "资源快照已清除"
        } catch {
            bannerMessage = "清除资源快照失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    func replaceProfile(_ update: (inout NulConnectProfile) -> Void) {
        var copy = profile
        update(&copy)
        profile = copy
    }

    func currentSessionMaterial() -> ATRSessionMaterial? {
        storedSessionMaterial
    }

    private func preferredWebLoginMethod(in methods: [ATRAuthMethod]) -> ATRAuthMethod? {
        guard !methods.isEmpty else {
            return nil
        }

        if let preferredAuthType = profile.preferredAuthType {
            if !profile.loginDomain.isEmpty, let method = methods.first(where: { $0.loginDomain == profile.loginDomain && $0.authType == preferredAuthType }) {
                return method
            }
            if let method = methods.first(where: { $0.authType == preferredAuthType }) {
                return method
            }
        }

        if !profile.loginDomain.isEmpty, let method = methods.first(where: { $0.loginDomain == profile.loginDomain }) {
            return method
        }

        return methods.first
    }

    private func capturePolicy(for method: ATRAuthMethod) -> NulConnectWebLoginCapturePolicy? {
        switch method.authType {
        case "auth/cas":
            return .cas(baseHost: profile.serverHost)
        case "auth/httpsOauth2":
            return .httpsOauth2(baseHost: profile.serverHost)
        default:
            return nil
        }
    }

    private func refreshResourceSnapshotAfterLogin(session material: ATRSessionMaterial) async -> ATRResourceSnapshot? {
        do {
            let resourceBytes = try await authEngine.fetchClientResource()
            print("[NulConnect][Login] fetched client resource bytes=\(resourceBytes.count) preview='\(Self.resourcePreview(resourceBytes))'")
            let client = try ATRClient(configuration: clientConfiguration)
            try client.setSession(material)
            try client.setResource(resourceBytes, serviceHost: profile.serverHost)
            let snapshot = try client.resourceSnapshot()
            print("[NulConnect][Login] resource snapshot refreshed: bytes=\(snapshot.resourceBytes.count) ip=\(snapshot.ipResources.count) domain=\(snapshot.domainResources.count) dns=\(snapshot.dnsResources.count) nodes=\(snapshot.nodeGroups.count)")
            return snapshot
        } catch {
            await MainActor.run {
                self.lastPersistenceErrorMessage = error.localizedDescription
            }
            print("[NulConnect][Login] resource snapshot refresh failed: \(error)")
            return nil
        }
    }

    private nonisolated static func resourcePreview(_ data: Data) -> String {
        String(decoding: data.prefix(600), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    var proxyEndpointText: String {
        switch proxyState {
        case .running(let endpoint):
            return endpoint.displayString
        default:
            return "127.0.0.1:1080"
        }
    }

    var loginStateText: String {
        loginState.title
    }

    var loginStateDetailText: String? {
        loginState.detail
    }

    var webLoginMethods: [ATRAuthMethod] {
        availableLoginMethods.filter { capturePolicy(for: $0) != nil }
    }

    func refreshLoginMethods() {
        guard isLoginConfigurationReady else {
            loginState = .idle
            availableLoginMethods = []
            bannerMessage = "请先填写服务地址并保存"
            print("[NulConnect][Login] skip refresh: invalid server host='\(profile.serverHost)' port=\(profile.serverPort) loginDomain='\(profile.loginDomain)'")
            return
        }

        loginTask?.cancel()
        loginState = .loadingMethods
        bannerMessage = "正在获取 HIT 登录方式"
        print("[NulConnect][Login] refresh methods start: serverHost='\(profile.serverHost)' port=\(profile.serverPort) loginDomain='\(profile.loginDomain)' preferredAuthType='\(profile.preferredAuthType ?? "")' clientType='\(profile.clientType)' platform='\(profile.platform)' allowInsecureTLS=\(profile.allowInsecureTLS)")

        let configuration = authConfiguration
        loginTask = Task { [authEngine] in
            do {
                let methods = try await authEngine.loadMethods(configuration: configuration)
                let supportedCount = methods.filter { self.capturePolicy(for: $0) != nil }.count
                await MainActor.run {
                    self.availableLoginMethods = methods
                    self.loginState = supportedCount > 0 ? .ready(methodCount: supportedCount) : .failed(message: NulConnectLoginError.noWebLoginMethods.localizedDescription)
                    self.bannerMessage = methods.isEmpty ? "未获取到登录方式" : "已刷新登录方式"
                    self.lastPersistenceErrorMessage = nil
                    print("[NulConnect][Login] refresh methods success: total=\(methods.count) supported=\(supportedCount)")
                    for method in methods {
                        print("[NulConnect][Login] method: loginDomain='\(method.loginDomain)' authType='\(method.authType)' authName='\(method.authName)' loginURL='\(method.loginURL)'")
                    }
                }
            } catch {
                await MainActor.run {
                    self.loginState = .failed(message: error.localizedDescription)
                    self.bannerMessage = "获取登录方式失败: \(error.localizedDescription)"
                    self.lastPersistenceErrorMessage = error.localizedDescription
                    print("[NulConnect][Login] refresh methods failed: \(error)")
                }
            }
        }
    }

    func startWebLogin(using method: ATRAuthMethod? = nil) {
        guard isLoginConfigurationReady else {
            loginState = .failed(message: "请先在设置中填写服务地址")
            bannerMessage = "请先填写服务地址并保存"
            return
        }

        loginTask?.cancel()
        loginState = .loadingMethods
        bannerMessage = "正在准备 HIT WebView 登录"

        let configuration = authConfiguration
        loginTask = Task { [authEngine] in
            do {
                let methods = try await authEngine.loadMethods(configuration: configuration)
                let supportedMethods = methods.filter { self.capturePolicy(for: $0) != nil }
                let targetMethod = method ?? self.preferredWebLoginMethod(in: supportedMethods)
                guard let targetMethod else {
                    await MainActor.run {
                        self.availableLoginMethods = methods
                        self.loginState = .failed(message: NulConnectLoginError.noWebLoginMethods.localizedDescription)
                        self.bannerMessage = NulConnectLoginError.noWebLoginMethods.localizedDescription
                        self.lastPersistenceErrorMessage = NulConnectLoginError.noWebLoginMethods.localizedDescription
                    }
                    return
                }

                let session = try await authEngine.resolveWebLoginSession(for: targetMethod)
                await MainActor.run {
                    self.availableLoginMethods = methods
                    self.webLoginSession = session
                    self.loginState = .presenting(methodName: targetMethod.authName.isEmpty ? targetMethod.authType : targetMethod.authName)
                    self.bannerMessage = "已打开 \(session.title)"
                    self.lastPersistenceErrorMessage = nil
                    print("[NulConnect][Login] open web session title='\(session.title)' subtitle='\(session.subtitle)' startURL='\(session.startURL.absoluteString)'")
                }
            } catch {
                await MainActor.run {
                    self.loginState = .failed(message: error.localizedDescription)
                    self.bannerMessage = "打开登录失败: \(error.localizedDescription)"
                    self.lastPersistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelWebLogin() {
        loginTask?.cancel()
        loginTask = nil
        webLoginSession = nil
        if case .succeeded = loginState {
            return
        }
        loginState = .idle
        bannerMessage = "已取消登录"
    }

    func completeWebLogin(with callbackURL: URL) {
        guard let session = webLoginSession else {
            bannerMessage = "登录会话不存在"
            return
        }

        loginState = .finalizing
        bannerMessage = "正在完成 HIT 登录"
        print("[NulConnect][Login] complete web login callbackURL='\(callbackURL.absoluteString)' methodAuthType='\(session.method.authType)' loginDomain='\(session.method.loginDomain)'")

        loginTask?.cancel()
        loginTask = Task { [authEngine] in
            do {
                let challenge = try await authEngine.completeWebLogin(callbackURL: callbackURL, method: session.method)
                switch challenge {
                case .done(let material):
                    await MainActor.run {
                        self.saveSessionMaterial(material)
                        self.loginState = .succeeded(message: "会话已保存")
                        self.webLoginSession = nil
                        self.bannerMessage = "HIT 登录成功"
                    }

                    if let snapshot = await refreshResourceSnapshotAfterLogin(session: material) {
                        await MainActor.run {
                            self.saveResourceSnapshot(snapshot)
                        }
                    }
                case .callbackURL(let url, let kind):
                    await MainActor.run {
                        self.loginState = .failed(message: "还需要继续处理回调: \(kind)")
                        self.bannerMessage = "登录需要继续跳转: \(url)"
                        self.lastPersistenceErrorMessage = nil
                        print("[NulConnect][Login] complete web login returned callback kind=\(kind) url='\(url)'")
                    }
                case .captcha:
                    await MainActor.run {
                        self.loginState = .failed(message: "登录需要验证码，当前链路未实现")
                        self.bannerMessage = "登录流程返回验证码挑战"
                        print("[NulConnect][Login] complete web login returned captcha challenge")
                    }
                case .smsCode:
                    await MainActor.run {
                        self.loginState = .failed(message: "登录需要短信验证码，当前链路未实现")
                        self.bannerMessage = "登录流程返回短信验证码挑战"
                        print("[NulConnect][Login] complete web login returned sms challenge")
                    }
                }
            } catch {
                await MainActor.run {
                    self.loginState = .failed(message: error.localizedDescription)
                    self.bannerMessage = "完成登录失败: \(error.localizedDescription)"
                    self.lastPersistenceErrorMessage = error.localizedDescription
                    print("[NulConnect][Login] complete web login failed: \(error)")
                }
            }
        }
    }

    func startProxyMode() {
        guard profile.routeMode == .proxy else {
            bannerMessage = "当前不是代理模式"
            return
        }
        guard isReadyForProxyMode else {
            startWebLogin()
            return
        }
        guard proxyService == nil else {
            bannerMessage = "代理已经在运行"
            return
        }

        proxyState = .starting
        connectionState = NulConnectConnectionState(
            phase: .connecting,
            message: "正在启动本地代理",
            updatedAt: .now
        )

        let profile = self.profile
        let session = storedSessionMaterial
        let resource = resourceSnapshot

        proxyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let service = try await NulConnectProxyService(
                    profile: profile,
                    session: session,
                    resource: resource
                )
                let endpoint = try await service.start()
                await MainActor.run {
                    self.proxyService = service
                    self.proxyState = .running(endpoint: endpoint)
                    self.connectionState = NulConnectConnectionState(
                        phase: .connected,
                        message: "本地代理已启动 \(endpoint.displayString)",
                        updatedAt: .now
                    )
                    self.bannerMessage = "代理模式已启动"
                    self.lastPersistenceErrorMessage = nil
                }

                await service.probeSOCKS5()
            } catch {
                await MainActor.run {
                    self.proxyService = nil
                    self.proxyState = .failed(message: error.localizedDescription)
                    self.connectionState = NulConnectConnectionState(
                        phase: .failed,
                        message: error.localizedDescription,
                        updatedAt: .now
                    )
                    self.bannerMessage = "启动代理失败: \(error.localizedDescription)"
                    self.lastPersistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func stopProxyMode() {
        guard proxyService != nil else {
            proxyState = .stopped
            connectionState = NulConnectConnectionState(
                phase: .disconnected,
                message: "代理未运行",
                updatedAt: .now
            )
            return
        }

        proxyState = .stopping
        connectionState = NulConnectConnectionState(
            phase: .disconnecting,
            message: "正在停止本地代理",
            updatedAt: .now
        )

        proxyService?.stop()
        proxyService = nil
        proxyTask?.cancel()
        proxyTask = nil
        proxyState = .stopped
        connectionState = NulConnectConnectionState(
            phase: .disconnected,
            message: "代理已停止",
            updatedAt: .now
        )
        bannerMessage = "代理模式已停止"
    }

    private func scheduleProfilePersistence() {
        guard !suppressProfilePersistence else {
            return
        }
        profilePersistenceTask?.cancel()
        let snapshot = profile
        profilePersistenceTask = Task { [profileStore] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try profileStore.save(snapshot)
                await MainActor.run {
                    self.lastPersistenceErrorMessage = nil
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.lastPersistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }
}
