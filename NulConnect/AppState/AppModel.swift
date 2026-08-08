import Combine
import Foundation
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
    @Published private(set) var systemProxyState: NulConnectSystemProxyRuntimeState = .disabled
    @Published private(set) var tunnelState: NulConnectTunnelRuntimeState = .stopped
    @Published private(set) var loginState: NulConnectLoginState = .idle
    @Published private(set) var availableLoginMethods: [ATRAuthMethod] = []
    @Published var webLoginSession: NulConnectWebLoginSession?
    @Published private(set) var sessionSummary: NulConnectSessionSummary?
    @Published private(set) var resourceSnapshot: ATRResourceSnapshot?
    @Published private(set) var bannerMessage: String?
    @Published private(set) var lastPersistenceErrorMessage: String?
    @Published private(set) var helperActivityState: NulConnectHelperActivityState = .idle
    @Published private(set) var helperVersionText: String = "未安装"
    @Published private(set) var bundledHelperVersionText: String = "读取中"
    @Published private(set) var isLoggingOut = false

    let trafficStore = NulConnectTrafficStore()

    private let authEngine = NulConnectAuthEngine()
    private let profileStore: ProfileStore
    private let sessionVault: SessionVault
    private let resourceStore: ResourceSnapshotStore
    private let systemProxyManager: NulConnectSystemProxyManager?
    private let tunnelManager: NulConnectTunnelManager?
    private let helperClient = NulConnectHelperClient()
    private var profilePersistenceTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var proxyService: NulConnectProxyService?
    private var tunnelProxyService: NulConnectProxyService?
    private var proxyTask: Task<Void, Never>?
    private var tunnelTask: Task<Void, Never>?
    private var tunnelHealthTask: Task<Void, Never>?
    private var trafficSamplingTask: Task<Void, Never>?
    private var pendingConnectionMode: NulConnectRouteMode?
    private var isRecoveringTunnelSession = false
    private var helperVersionsLoaded = false
    private var storedSessionMaterial: ATRSessionMaterial?
    private var suppressProfilePersistence = false
    private var isStatisticsVisible = false
    private var isMenuBarVisible = false
    private var trafficCounterOffset: NulConnectTrafficCounters = .zero
    private var previousTrafficSample: (counters: NulConnectTrafficCounters, instant: ContinuousClock.Instant)?

    private var trafficStatistics: NulConnectTrafficStatistics {
        get { trafficStore.statistics }
        set { trafficStore.update(newValue) }
    }

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
        self.systemProxyState = .disabled
        self.sessionSummary = sessionSummary
        self.resourceSnapshot = resourceSnapshot
        self.bannerMessage = bannerMessage
        self.storedSessionMaterial = storedSessionMaterial
        self.systemProxyManager = try? NulConnectSystemProxyManager()
        self.tunnelManager = try? NulConnectTunnelManager()
    }

    static func bootstrap() -> AppModel {
        do {
            let profileStore = try ProfileStore()
            let sessionVault = try SessionVault()
            let resourceStore = try ResourceSnapshotStore()
            let profile = try profileStore.load()
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
                let profile = (try? profileStore.load()) ?? .default
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
        guard isHelperInstalled else {
            return false
        }
        if case .enabled = systemProxyState {
            return true
        }
        return runtimeProfile.useSystemProxy
    }

    var effectiveRouteMode: NulConnectRouteMode {
        isHelperInstalled ? runtimeProfile.routeMode : .proxy
    }

    var routePresentationModeTitle: String {
        switch effectiveRouteMode {
        case .tun:
            return NulConnectRouteMode.tun.title
        case .proxy:
            return effectiveSystemProxyEnabled ? "系统代理" : NulConnectRouteMode.proxy.title
        }
    }

    var isTunnelFeatureAvailable: Bool {
        tunnelManager != nil
    }

    var isHelperInstalled: Bool {
        helperClient.isInstalled()
    }

    var isHelperActivityBusy: Bool {
        helperActivityState.isBusy
    }

    func refreshHelperVersion(force: Bool = false) {
        guard force || !helperVersionsLoaded else { return }
        helperVersionsLoaded = true
        helperVersionText = isHelperInstalled ? "读取中" : "未安装"
        bundledHelperVersionText = "读取中"
        Task {
            async let installed = helperClient.installedVersionString()
            async let bundled = helperClient.bundledVersionString()
            helperVersionText = await installed ?? (isHelperInstalled ? "未知" : "未安装")
            bundledHelperVersionText = await bundled ?? "未知"
        }
    }

    var tunnelUnavailableMessage: String {
        "VPN 模式需要可用的特权组件。"
    }

    var isProxyRunning: Bool {
        if case .running = proxyState {
            return true
        }
        return false
    }

    var isProxyBusy: Bool {
        switch proxyState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    var isVPNConnectedOrConnecting: Bool {
        switch connectionState.phase {
        case .connecting, .connected, .disconnecting:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    var isSystemProxyEnabled: Bool {
        if case .enabled = systemProxyState {
            return true
        }
        return false
    }

    var isSystemProxyBusy: Bool {
        switch systemProxyState {
        case .enabling, .disabling:
            return true
        default:
            return false
        }
    }

    var canChangeSystemProxyPreference: Bool {
        effectiveRouteMode == .proxy && isHelperInstalled && !isProxyBusy && !isTunnelRunning && !isTunnelBusy
    }

    var effectiveSystemProxyPreference: Bool {
        isHelperInstalled ? runtimeProfile.useSystemProxy : false
    }

    var effectiveRouteModePreference: NulConnectRouteMode {
        isHelperInstalled ? runtimeProfile.routeMode : .proxy
    }

    var canUseTunnelMode: Bool {
        isHelperInstalled && tunnelManager != nil
    }

    var isTunnelRunning: Bool {
        if case .running = tunnelState {
            return true
        }
        return false
    }

    var isTunnelBusy: Bool {
        switch tunnelState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    var requiresNetworkCleanupForTermination: Bool {
        isProxyRunning ||
            isProxyBusy ||
            isSystemProxyEnabled ||
            isSystemProxyBusy ||
            isTunnelRunning ||
            isTunnelBusy ||
            tunnelProxyService != nil
    }

    var menuBarSystemImage: String {
        switch connectionState.phase {
        case .connected:
            return "checkmark.shield.fill"
        case .connecting, .disconnecting:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "shield"
        }
    }

    var isLoginConfigurationReady: Bool {
        let host = profile.serverHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !host.isEmpty && host != "localhost" && host != "127.0.0.1"
    }

    var isReadyForProxyMode: Bool {
        storedSessionMaterial != nil
    }

    var isReadyForTunnelMode: Bool {
        storedSessionMaterial != nil
    }

    var needsHITLoginForProxy: Bool {
        !isReadyForProxyMode
    }

    var needsHITLoginForTunnel: Bool {
        !isReadyForTunnelMode
    }

    var clientConfiguration: ATRClientConfiguration {
        let runtimeProfile = self.runtimeProfile
        return ATRClientConfiguration(
            serverHost: runtimeProfile.serverHost,
            serverPort: runtimeProfile.serverPort,
            userAgent: runtimeProfile.userAgent,
            connectTimeout: runtimeProfile.connectTimeoutMillis,
            ioTimeout: runtimeProfile.ioTimeoutMillis,
            nodeProbeTimeout: runtimeProfile.nodeProbeTimeoutMillis,
            allowInsecureTLS: runtimeProfile.allowInsecureTLS
        )
    }

    var authConfiguration: ATRAuthConfiguration {
        let runtimeProfile = self.runtimeProfile
        return ATRAuthConfiguration(
            serverHost: runtimeProfile.serverHost,
            serverPort: runtimeProfile.serverPort,
            userAgent: runtimeProfile.userAgent,
            clientType: runtimeProfile.clientType,
            platform: runtimeProfile.platform,
            loginDomain: runtimeProfile.loginDomain,
            preferredAuthType: runtimeProfile.preferredAuthType,
            ioTimeout: runtimeProfile.ioTimeoutMillis,
            allowInsecureTLS: runtimeProfile.allowInsecureTLS
        )
    }

    func reloadPersistedState() {
        do {
            suppressProfilePersistence = true
            profile = try profileStore.load()
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

    func logout() {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        bannerMessage = "正在退出登录"
        pendingConnectionMode = nil
        Task { [weak self] in
            guard let self else { return }
            await self.prepareForApplicationTermination()
            await self.authEngine.reset()
            await NulConnectWebDataStore.clearLoginData()
            do {
                try self.sessionVault.clear()
                try self.resourceStore.delete()
                self.storedSessionMaterial = nil
                self.sessionSummary = nil
                self.resourceSnapshot = nil
                self.availableLoginMethods = []
                self.webLoginSession = nil
                self.loginState = .idle
                self.lastPersistenceErrorMessage = nil
                self.bannerMessage = "已退出登录"
            } catch {
                self.bannerMessage = "退出登录失败: \(error.localizedDescription)"
                self.lastPersistenceErrorMessage = error.localizedDescription
            }
            self.isLoggingOut = false
        }
    }

    func setStatisticsVisible(_ visible: Bool) {
        isStatisticsVisible = visible
        updateTrafficSamplingState()
    }

    func setMenuBarVisible(_ visible: Bool) {
        isMenuBarVisible = visible
        updateTrafficSamplingState()
    }

    private func updateTrafficSamplingState() {
        if isTrafficMonitoringRequested {
            startTrafficSampling()
        } else {
            stopTrafficSampling()
            previousTrafficSample = nil
            trafficStatistics.uploadBytesPerSecond = 0
            trafficStatistics.downloadBytesPerSecond = 0
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

    func uninstallHelper() {
        guard !isVPNConnectedOrConnecting else {
            bannerMessage = "VPN 连接中或已连接时不能卸载特权组件"
            return
        }
        bannerMessage = "正在卸载特权组件"
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.stopAllNetworkModes()
            do {
                try self.helperClient.uninstall()
                await MainActor.run {
                    self.bannerMessage = "特权组件已卸载"
                    self.lastPersistenceErrorMessage = nil
                    self.refreshHelperVersion(force: true)
                }
            } catch {
                await MainActor.run {
                    self.bannerMessage = "卸载特权组件失败: \(error.localizedDescription)"
                    self.lastPersistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func reportHelperActivity(_ state: NulConnectHelperActivityState) {
        helperActivityState = state
        if let message = state.message {
            bannerMessage = message
        }
    }

    func ensureHelperInstalledOrUpToDate(reason: String) async throws {
        guard !isVPNConnectedOrConnecting else {
            bannerMessage = "VPN 连接中或已连接时不能安装或更新特权组件"
            throw NulConnectHelperClientError.commandFailed("VPN 连接中或已连接时不能安装或更新特权组件")
        }
        await MainActor.run {
            self.reportHelperActivity(.checking)
            self.bannerMessage = "正在检查特权组件"
            self.lastPersistenceErrorMessage = nil
        }

        let needsInstallOrUpgrade = try await helperClient.requiresInstallOrUpgrade()
        guard needsInstallOrUpgrade else {
            await MainActor.run {
                self.reportHelperActivity(.succeeded(message: "特权组件已是最新"))
                self.refreshHelperVersion(force: true)
            }
            return
        }

        do {
            await MainActor.run {
                self.reportHelperActivity(.installing(message: reason))
            }
            try await helperClient.ensureInstalledOrUpToDate(reporter: { [weak self] state in
                self?.helperActivityState = state
                if let message = state.message {
                    self?.bannerMessage = message
                }
            })
            await MainActor.run {
                self.reportHelperActivity(.waitingForStart(message: "特权组件已安装，等待服务启动"))
            }
            await MainActor.run {
                self.reportHelperActivity(.succeeded(message: "特权组件已准备就绪"))
                self.refreshHelperVersion(force: true)
            }
        } catch {
            await MainActor.run {
                self.reportHelperActivity(.failed(message: error.localizedDescription))
                self.bannerMessage = "特权组件安装失败: \(error.localizedDescription)"
                self.lastPersistenceErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func replaceProfile(_ update: (inout NulConnectProfile) -> Void) {
        var copy = profile
        update(&copy)
        profile = copy
    }

    func setSystemProxyEnabled(_ enabled: Bool) {
        guard isHelperInstalled else {
            replaceProfile { profile in
                profile.useSystemProxy = false
            }
            systemProxyState = .disabled
            bannerMessage = "请先在“特权组件”页安装 helper"
            return
        }
        replaceProfile { profile in
            profile.useSystemProxy = enabled
        }

        guard case .running(let endpoint) = proxyState else {
            bannerMessage = enabled ? "系统代理将在代理启动后自动开启" : "系统代理偏好已关闭"
            return
        }

        if enabled {
            Task {
                await enableSystemProxy(endpoint: endpoint)
            }
        } else {
            Task {
                await disableSystemProxy()
            }
        }
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

    private func normalizeLoginSelectionDefaults(using methods: [ATRAuthMethod]) {
        guard !methods.isEmpty else {
            return
        }

        let suggestedMethod = preferredWebLoginMethod(in: methods) ?? methods[0]
        let validLoginDomains = Set(methods.map(\.loginDomain))
        let validAuthTypes = Set(methods.map(\.authType))
        let needsLoginDomainUpdate = profile.loginDomain.isEmpty || !validLoginDomains.contains(profile.loginDomain)
        let needsPreferredAuthUpdate = profile.preferredAuthType == nil || !validAuthTypes.contains(profile.preferredAuthType ?? "")

        guard needsLoginDomainUpdate || needsPreferredAuthUpdate else {
            return
        }

        replaceProfile { profile in
            if needsLoginDomainUpdate {
                profile.loginDomain = suggestedMethod.loginDomain
            }
            if needsPreferredAuthUpdate {
                profile.preferredAuthType = suggestedMethod.authType
            }
        }
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

    private func refreshStoredSessionAndResourceForProxy() async throws -> (ATRSessionMaterial, ATRResourceSnapshot) {
        guard let storedSessionMaterial else {
            throw NulConnectProxyServiceError.missingSession
        }

        print("[NulConnect][Login] resume stored session start user='\(storedSessionMaterial.username)' deviceID='\(storedSessionMaterial.deviceID)'")
        do {
            let refreshedMaterial = try await authEngine.resumeSession(storedSessionMaterial, configuration: authConfiguration)
            try sessionVault.save(refreshedMaterial)
            self.storedSessionMaterial = refreshedMaterial
            self.sessionSummary = NulConnectSessionSummary(material: refreshedMaterial)
            print("[NulConnect][Login] resume stored session success user='\(refreshedMaterial.username)' sidBytes=\(refreshedMaterial.sid.utf8.count) cookies=\(refreshedMaterial.cookies.count)")

            let resourceBytes = try await authEngine.fetchClientResource()
            print("[NulConnect][Login] refreshed client resource before proxy bytes=\(resourceBytes.count) preview='\(Self.resourcePreview(resourceBytes))'")
            let client = try ATRClient(configuration: clientConfiguration)
            try client.setSession(refreshedMaterial)
            try client.setResource(resourceBytes, serviceHost: profile.serverHost)
            let snapshot = try client.resourceSnapshot()
            try resourceStore.save(snapshot)
            self.resourceSnapshot = snapshot
            print("[NulConnect][Login] refreshed resource before proxy: bytes=\(snapshot.resourceBytes.count) ip=\(snapshot.ipResources.count) domain=\(snapshot.domainResources.count) dns=\(snapshot.dnsResources.count) nodes=\(snapshot.nodeGroups.count)")
            return (refreshedMaterial, snapshot)
        } catch {
            if Self.isStoredSessionInvalidError(error) {
                await invalidateStoredSession(message: "登录会话已失效，请重新登录", error: error)
                throw NulConnectProxyServiceError.sessionExpired("登录会话已失效，请重新登录")
            }
            throw error
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
            return "127.0.0.1:\(runtimeProfile.localProxyPort)"
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
        let runtimeProfile = self.runtimeProfile
        print("[NulConnect][Login] refresh methods start: serverHost='\(runtimeProfile.serverHost)' port=\(runtimeProfile.serverPort) loginDomain='\(runtimeProfile.loginDomain)' preferredAuthType='\(runtimeProfile.preferredAuthType ?? "")' clientType='\(runtimeProfile.clientType)' platform='\(runtimeProfile.platform)' allowInsecureTLS=\(runtimeProfile.allowInsecureTLS)")

        let configuration = authConfiguration
        loginTask = Task { [authEngine] in
            do {
                let methods = try await authEngine.loadMethods(configuration: configuration)
                await MainActor.run {
                    self.normalizeLoginSelectionDefaults(using: methods)
                    let supportedCount = methods.filter { self.capturePolicy(for: $0) != nil }.count
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

                let deviceID = try self.sessionVault.loadOrCreateDeviceID()
                let session = try await authEngine.resolveWebLoginSession(for: targetMethod, deviceID: deviceID)
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
        pendingConnectionMode = nil
        if case .succeeded = loginState {
            return
        }
        loginState = .idle
        bannerMessage = "已取消登录"
    }

    private func requestWebLogin(toContinue mode: NulConnectRouteMode) {
        pendingConnectionMode = mode
        startWebLogin()
    }

    private func continuePendingConnectionAfterLogin() {
        guard let mode = pendingConnectionMode else { return }
        pendingConnectionMode = nil
        switch mode {
        case .proxy:
            startProxyMode()
        case .tun:
            startTunnelMode()
        }
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
                        if !self.isProxyRunning {
                            self.connectionState = NulConnectConnectionState(
                                phase: .disconnected,
                                message: "已登录，可启动代理",
                                updatedAt: .now
                            )
                        }
                        self.bannerMessage = "HIT 登录成功"
                    }

                    if let snapshot = await refreshResourceSnapshotAfterLogin(session: material) {
                        await MainActor.run {
                            self.saveResourceSnapshot(snapshot)
                        }
                    }
                    await MainActor.run {
                        self.continuePendingConnectionAfterLogin()
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

    private func enableSystemProxy(endpoint: NulConnectProxyEndpoint) async {
        guard let systemProxyManager else {
            systemProxyState = .failed(message: "系统代理管理器不可用")
            bannerMessage = "系统代理管理器不可用"
            return
        }

        guard isHelperInstalled else {
            systemProxyState = .disabled
            replaceProfile { profile in
                profile.useSystemProxy = false
            }
            bannerMessage = "请先在“特权组件”页安装 helper"
            return
        }

        systemProxyState = .enabling
        do {
            let serviceCount = try await systemProxyManager.enable(
                endpoint: endpoint,
                serverHost: runtimeProfile.serverHost,
                helperActivityReporter: { [weak self] state in
                    self?.helperActivityState = state
                    if let message = state.message {
                        self?.bannerMessage = message
                    }
                }
            )
            systemProxyState = .enabled(endpoint: endpoint)
            bannerMessage = "系统代理已开启，已配置 \(serviceCount) 个网络服务"
            lastPersistenceErrorMessage = nil
        } catch {
            systemProxyState = .failed(message: error.localizedDescription)
            bannerMessage = "开启系统代理失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    private func disableSystemProxy() async {
        guard let systemProxyManager else {
            systemProxyState = .disabled
            return
        }

        switch systemProxyState {
        case .enabled, .enabling, .failed:
            systemProxyState = .disabling
        case .disabled, .disabling:
            return
        }

        do {
            try await systemProxyManager.restore()
            systemProxyState = .disabled
            bannerMessage = "系统代理已关闭"
            lastPersistenceErrorMessage = nil
        } catch {
            systemProxyState = .failed(message: error.localizedDescription)
            bannerMessage = "关闭系统代理失败: \(error.localizedDescription)"
            lastPersistenceErrorMessage = error.localizedDescription
        }
    }

    func startProxyMode() {
        guard effectiveRouteMode == .proxy else {
            bannerMessage = "当前不是代理模式"
            return
        }
        guard !isTunnelRunning && !isTunnelBusy else {
            bannerMessage = "请先停止 VPN 模式"
            return
        }
        guard storedSessionMaterial != nil else {
            requestWebLogin(toContinue: .proxy)
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

        let profile = runtimeProfile
        proxyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (session, resource) = try await self.refreshStoredSessionAndResourceForProxy()
                let service = try await NulConnectProxyService(
                    profile: profile,
                    session: session,
                    resource: resource,
                    listenPort: profile.localProxyPort
                )
                service.onSessionInvalidated = { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.handleProxySessionInvalidated(error)
                    }
                }
                let endpoint = try await service.start()
                await MainActor.run {
                    self.proxyService = service
                    self.proxyState = .running(endpoint: endpoint)
                    self.beginTrafficSession(continuing: false)
                    self.connectionState = NulConnectConnectionState(
                        phase: .connected,
                        message: "本地代理已启动 \(endpoint.displayString)",
                        updatedAt: .now
                    )
                    self.bannerMessage = "代理模式已启动"
                    self.lastPersistenceErrorMessage = nil
                }

                if profile.useSystemProxy {
                    await self.enableSystemProxy(endpoint: endpoint)
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
                    if Self.requiresWebLogin(error) {
                        self.requestWebLogin(toContinue: .proxy)
                    }
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

        proxyTask?.cancel()
        proxyTask = Task { [weak self] in
            guard let self else { return }
            await self.disableSystemProxy()
            await MainActor.run {
                self.finishStoppingProxyMode()
            }
        }
    }

    private func finishStoppingProxyMode() {
        captureProxyTrafficBeforeStop()
        proxyService?.stop()
        proxyService = nil
        proxyTask = nil
        proxyState = .stopped
        connectionState = NulConnectConnectionState(
            phase: .disconnected,
            message: "代理已停止",
            updatedAt: .now
        )
        bannerMessage = "代理模式已停止"
        finishTrafficSession()
    }

    func startTunnelMode() {
        guard effectiveRouteMode == .tun else {
            bannerMessage = "当前不是 VPN 模式"
            return
        }
        guard isHelperInstalled else {
            bannerMessage = "请先在“特权组件”页安装 helper"
            return
        }
        guard let tunnelManager else {
            tunnelState = .failed(message: tunnelUnavailableMessage)
            connectionState = NulConnectConnectionState(
                phase: .failed,
                message: tunnelUnavailableMessage,
                updatedAt: .now
            )
            bannerMessage = tunnelUnavailableMessage
            return
        }
        guard !isProxyRunning && !isProxyBusy else {
            bannerMessage = "请先停止代理模式"
            return
        }
        guard storedSessionMaterial != nil else {
            requestWebLogin(toContinue: .tun)
            return
        }
        guard !isTunnelRunning && !isTunnelBusy else {
            bannerMessage = "VPN 已经在运行"
            return
        }

        tunnelState = .starting
        connectionState = NulConnectConnectionState(
            phase: .connecting,
            message: "正在启动 VPN 模式",
            updatedAt: .now
        )

        let profile = runtimeProfile
        let clientConfiguration = self.clientConfiguration
        tunnelTask = Task { [weak self] in
            guard let self else { return }
            do {
                NulConnectDiagnostics.log("[NulConnect][Tunnel] startTunnelMode: refreshing session and resource")
                let (session, resource) = try await self.refreshStoredSessionAndResourceForProxy()
                NulConnectDiagnostics.log("[NulConnect][Tunnel] startTunnelMode: resource ip=\(resource.ipResources.count) domain=\(resource.domainResources.count) dns=\(resource.dnsResources.count) excluded=\(resource.excludedIPs.count) dnsServer=\(resource.dnsServer ?? "nil") nodes=\(resource.nodeGroups.count)")
                let configuration = await NulConnectTunnelManager.makeLaunchConfiguration(
                    profile: clientConfiguration,
                    session: session,
                    resource: resource,
                    serverHost: profile.serverHost
                )
                NulConnectDiagnostics.log("[NulConnect][Tunnel] startTunnelMode: launch config dns=\(configuration.dnsAddress) mtu=\(configuration.mtu) setupRoutes=\(configuration.setupRoutes) managedRoutes=\(configuration.managedRouteCIDRs.count) [\(configuration.managedRouteCIDRs.prefix(16).joined(separator: ", "))]")
                try await tunnelManager.start(
                    configuration: configuration,
                    helperActivityReporter: { [weak self] state in
                        self?.helperActivityState = state
                        if let message = state.message {
                            self?.bannerMessage = message
                        }
                    }
                )
                await MainActor.run {
                    self.tunnelState = .running
                    self.beginTrafficSession(continuing: self.isRecoveringTunnelSession)
                    self.connectionState = NulConnectConnectionState(
                        phase: .connected,
                        message: "VPN 模式已启动",
                        updatedAt: .now
                    )
                    self.bannerMessage = "VPN 模式已启动"
                    self.lastPersistenceErrorMessage = nil
                    self.startTunnelHealthMonitor()
                    self.isRecoveringTunnelSession = false
                }
                await NulConnectDiagnostics.logNetworkSnapshot(reason: "tun-running")
            } catch {
                NulConnectDiagnostics.log("[NulConnect][Tunnel] startTunnelMode: failed error=\(error.localizedDescription)")
                try? await tunnelManager.stop()
                await MainActor.run {
                    self.stopTunnelHealthMonitor()
                    self.isRecoveringTunnelSession = false
                    self.tunnelProxyService?.stop()
                    self.tunnelProxyService = nil
                    self.tunnelState = .failed(message: error.localizedDescription)
                    self.connectionState = NulConnectConnectionState(
                        phase: .failed,
                        message: error.localizedDescription,
                        updatedAt: .now
                    )
                    self.bannerMessage = "启动 VPN 失败: \(error.localizedDescription)"
                    self.lastPersistenceErrorMessage = error.localizedDescription
                    if Self.requiresWebLogin(error) {
                        self.requestWebLogin(toContinue: .tun)
                    }
                }
            }
        }
    }

    func prepareForApplicationTermination() async {
        stopTunnelHealthMonitor()
        tunnelTask?.cancel()
        proxyTask?.cancel()

        if tunnelProxyService != nil || isTunnelRunning || isTunnelBusy {
            await captureTunnelTrafficBeforeStop()
            try? await tunnelManager?.stop()
            tunnelProxyService?.stop()
            tunnelProxyService = nil
            tunnelTask = nil
            tunnelState = .stopped
        }

        if isSystemProxyEnabled || isSystemProxyBusy {
            await disableSystemProxy()
        }

        if proxyService != nil {
            captureProxyTrafficBeforeStop()
            proxyService?.stop()
            proxyService = nil
            proxyTask = nil
            proxyState = .stopped
        }

        connectionState = NulConnectConnectionState(
            phase: .disconnected,
            message: "网络组件已停止",
            updatedAt: .now
        )
        finishTrafficSession()
    }

    func stopTunnelMode() {
        guard isTunnelRunning || isTunnelBusy else {
            tunnelState = .stopped
            connectionState = NulConnectConnectionState(
                phase: .disconnected,
                message: "VPN 未运行",
                updatedAt: .now
            )
            return
        }

        tunnelState = .stopping
        stopTunnelHealthMonitor()
        isRecoveringTunnelSession = false
        connectionState = NulConnectConnectionState(
            phase: .disconnecting,
            message: "正在停止 VPN 模式",
            updatedAt: .now
        )

        tunnelTask?.cancel()
        tunnelTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.captureTunnelTrafficBeforeStop()
                try await self.tunnelManager?.stop()
                await MainActor.run {
                    self.tunnelProxyService?.stop()
                    self.tunnelProxyService = nil
                    self.tunnelTask = nil
                    self.tunnelState = .stopped
                    self.connectionState = NulConnectConnectionState(
                        phase: .disconnected,
                        message: "VPN 已停止",
                        updatedAt: .now
                    )
                    self.bannerMessage = "VPN 模式已停止"
                    self.finishTrafficSession()
                }
            } catch {
                await MainActor.run {
                    self.tunnelTask = nil
                    self.tunnelState = .failed(message: error.localizedDescription)
                    self.connectionState = NulConnectConnectionState(
                        phase: .failed,
                        message: error.localizedDescription,
                        updatedAt: .now
                    )
                    self.bannerMessage = "停止 VPN 失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleProxySessionInvalidated(_ error: Error) {
        print("[NulConnect][Proxy] session invalidated: \(error)")
        let wasTunnelMode = tunnelProxyService != nil || isTunnelRunning || isTunnelBusy
        if wasTunnelMode {
            stopTunnelHealthMonitor()
            tunnelProxyService?.stop()
            tunnelProxyService = nil
            tunnelTask?.cancel()
            tunnelTask = nil
            Task { [tunnelManager] in
                try? await tunnelManager?.stop()
            }
            tunnelState = .failed(message: "登录会话已失效")
            failProxySessionInvalidated(error)
            requestWebLogin(toContinue: .tun)
            return
        }

        captureProxyTrafficBeforeStop()
        proxyService?.stop()
        proxyService = nil
        proxyTask?.cancel()
        proxyTask = nil

        guard storedSessionMaterial != nil else {
            failProxySessionInvalidated(error)
            requestWebLogin(toContinue: .proxy)
            return
        }

        proxyState = .starting
        connectionState = NulConnectConnectionState(
            phase: .connecting,
            message: "登录会话已失效，正在尝试恢复",
            updatedAt: .now
        )
        bannerMessage = "正在恢复登录会话"
        lastPersistenceErrorMessage = error.localizedDescription

        let profile = runtimeProfile
        proxyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (session, resource) = try await self.refreshStoredSessionAndResourceForProxy()
                let service = try await NulConnectProxyService(
                    profile: profile,
                    session: session,
                    resource: resource,
                    listenPort: profile.localProxyPort
                )
                service.onSessionInvalidated = { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.handleProxySessionInvalidated(error)
                    }
                }
                let endpoint = try await service.start()
                await MainActor.run {
                    self.proxyService = service
                    self.proxyState = .running(endpoint: endpoint)
                    self.beginTrafficSession(continuing: true)
                    self.connectionState = NulConnectConnectionState(
                        phase: .connected,
                        message: "本地代理已恢复 \(endpoint.displayString)",
                        updatedAt: .now
                    )
                    self.bannerMessage = "登录会话已恢复"
                    self.lastPersistenceErrorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.failProxySessionInvalidated(error)
                    self.requestWebLogin(toContinue: .proxy)
                }
            }
        }
    }

    private func invalidateStoredSession(message: String, error: Error) async {
        await authEngine.reset()
        try? sessionVault.clear()
        try? resourceStore.delete()
        storedSessionMaterial = nil
        sessionSummary = nil
        resourceSnapshot = nil
        loginState = .failed(message: message)
        connectionState = NulConnectConnectionState(
            phase: .failed,
            message: message,
            updatedAt: .now
        )
        bannerMessage = message
        lastPersistenceErrorMessage = error.localizedDescription
    }

    private nonisolated static func isStoredSessionInvalidError(_ error: Error) -> Bool {
        let normalized = error.localizedDescription.lowercased()
        if normalized.contains("stored session is not logged in")
            || normalized.contains("not logged in")
            || normalized.contains("invalid sid") {
            return true
        }

        switch error {
        case LibreATrustError.unauthorized(let message),
             LibreATrustError.invalidState(let message),
             LibreATrustError.networkFailed(let message):
            let text = message.lowercased()
            return text.contains("stored session is not logged in") || text.contains("not logged in") || text.contains("invalid sid")
        default:
            return false
        }
    }

    private nonisolated static func requiresWebLogin(_ error: Error) -> Bool {
        switch error {
        case NulConnectProxyServiceError.missingSession,
             NulConnectProxyServiceError.sessionExpired:
            return true
        default:
            return isStoredSessionInvalidError(error)
        }
    }

    private func failProxySessionInvalidated(_ error: Error) {
        stopTunnelHealthMonitor()
        try? sessionVault.clear()
        try? resourceStore.delete()
        storedSessionMaterial = nil
        sessionSummary = nil
        resourceSnapshot = nil

        proxyState = .failed(message: "登录会话已失效")
        connectionState = NulConnectConnectionState(
            phase: .failed,
            message: "登录会话已失效，请重新登录",
            updatedAt: .now
        )
        loginState = .failed(message: "登录会话已失效，请重新登录")
        bannerMessage = "登录会话已失效，请重新登录"
        lastPersistenceErrorMessage = error.localizedDescription
    }

    private func startTunnelHealthMonitor() {
        stopTunnelHealthMonitor()
        guard let tunnelManager else { return }
        tunnelHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    guard let status = try await tunnelManager.runtimeStatus() else {
                        continue
                    }
                    guard status.status == "failed" || status.status == "stopped" else {
                        continue
                    }
                    await self?.handleTunnelRuntimeStopped(status)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    NulConnectDiagnostics.log(
                        "[NulConnect][Tunnel] health monitor failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func stopTunnelHealthMonitor() {
        tunnelHealthTask?.cancel()
        tunnelHealthTask = nil
    }

    private func handleTunnelRuntimeStopped(_ status: NulConnectTunnelRuntimeStatus) async {
        stopTunnelHealthMonitor()
        let message = status.message ?? "VPN 特权组件已停止"
        let error = NulConnectTunnelManagerError.helperFailed(message)

        if Self.isStoredSessionInvalidError(error), !isRecoveringTunnelSession {
            isRecoveringTunnelSession = true
            tunnelState = .stopped
            connectionState = NulConnectConnectionState(
                phase: .connecting,
                message: "登录会话已失效，正在恢复 VPN",
                updatedAt: .now
            )
            bannerMessage = "正在恢复登录会话"
            startTunnelMode()
            return
        }

        isRecoveringTunnelSession = false
        tunnelState = .failed(message: message)
        connectionState = NulConnectConnectionState(
            phase: .failed,
            message: message,
            updatedAt: .now
        )
        bannerMessage = "VPN 运行失败: \(message)"
        lastPersistenceErrorMessage = message
    }

    private func stopAllNetworkModes() async {
        if isProxyRunning || isProxyBusy {
            stopProxyMode()
            try? await Task.sleep(for: .milliseconds(300))
        }
        if isTunnelRunning || isTunnelBusy {
            stopTunnelMode()
            try? await Task.sleep(for: .milliseconds(300))
        }
        if isSystemProxyEnabled || isSystemProxyBusy {
            await disableSystemProxy()
        }
    }

    private func beginTrafficSession(continuing: Bool) {
        if continuing {
            trafficCounterOffset = trafficStatistics.counters
        } else {
            trafficCounterOffset = .zero
            trafficStatistics = NulConnectTrafficStatistics(
                counters: .zero,
                uploadBytesPerSecond: 0,
                downloadBytesPerSecond: 0,
                connectionStartedAt: .now,
                connectionDuration: 0,
                isLive: true
            )
        }
        previousTrafficSample = nil
        if isTrafficMonitoringRequested {
            startTrafficSampling()
        }
    }

    private func finishTrafficSession() {
        stopTrafficSampling()
        previousTrafficSample = nil
        trafficStatistics.uploadBytesPerSecond = 0
        trafficStatistics.downloadBytesPerSecond = 0
        if let startedAt = trafficStatistics.connectionStartedAt {
            trafficStatistics.connectionDuration = max(0, Date().timeIntervalSince(startedAt))
        }
        trafficStatistics.isLive = false
    }

    private func startTrafficSampling() {
        guard isTrafficMonitoringRequested, isProxyRunning || isTunnelRunning else { return }
        guard trafficSamplingTask == nil else { return }
        trafficSamplingTask = Task { [weak self] in
            guard let self else { return }
            await self.sampleTraffic()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    try Task.checkCancellation()
                    await self.sampleTraffic()
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func stopTrafficSampling() {
        trafficSamplingTask?.cancel()
        trafficSamplingTask = nil
    }

    private var isTrafficMonitoringRequested: Bool {
        isStatisticsVisible || isMenuBarVisible
    }

    private func sampleTraffic() async {
        guard isProxyRunning || isTunnelRunning else {
            finishTrafficSession()
            return
        }
        do {
            let rawCounters = try await currentTrafficCounters()
            applyTrafficCounters(rawCounters, at: .now)
        } catch {
            // Statistics are auxiliary and must never affect the connection state.
        }
    }

    private func currentTrafficCounters() async throws -> NulConnectTrafficCounters {
        if isTunnelRunning, let tunnelManager,
           let status = try await tunnelManager.runtimeStatus() {
            return status.traffic
        }
        if let proxyService {
            return try proxyService.trafficCounters()
        }
        return .zero
    }

    private func applyTrafficCounters(_ rawCounters: NulConnectTrafficCounters, at date: Date) {
        let counters = Self.addTrafficCounters(trafficCounterOffset, rawCounters)
        let instant = ContinuousClock.now
        var uploadRate = 0.0
        var downloadRate = 0.0
        if let previousTrafficSample {
            let elapsed = previousTrafficSample.instant.duration(to: instant)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            if seconds > 0 {
                uploadRate = Double(Self.positiveDifference(
                    counters.uploadedBytes,
                    previousTrafficSample.counters.uploadedBytes
                )) / seconds
                downloadRate = Double(Self.positiveDifference(
                    counters.downloadedBytes,
                    previousTrafficSample.counters.downloadedBytes
                )) / seconds
            }
        }

        previousTrafficSample = (counters, instant)
        trafficStatistics.counters = counters
        trafficStatistics.uploadBytesPerSecond = uploadRate
        trafficStatistics.downloadBytesPerSecond = downloadRate
        if let startedAt = trafficStatistics.connectionStartedAt {
            trafficStatistics.connectionDuration = max(0, date.timeIntervalSince(startedAt))
        }
        trafficStatistics.isLive = true
    }

    private func captureProxyTrafficBeforeStop() {
        guard let counters = try? proxyService?.trafficCounters() else { return }
        applyTrafficCounters(counters, at: .now)
    }

    private func captureTunnelTrafficBeforeStop() async {
        guard let tunnelManager,
              let status = try? await tunnelManager.runtimeStatus() else { return }
        applyTrafficCounters(status.traffic, at: .now)
    }

    private nonisolated static func addTrafficCounters(
        _ lhs: NulConnectTrafficCounters,
        _ rhs: NulConnectTrafficCounters
    ) -> NulConnectTrafficCounters {
        NulConnectTrafficCounters(
            uploadedBytes: lhs.uploadedBytes &+ rhs.uploadedBytes,
            downloadedBytes: lhs.downloadedBytes &+ rhs.downloadedBytes,
            uploadedPackets: lhs.uploadedPackets &+ rhs.uploadedPackets,
            downloadedPackets: lhs.downloadedPackets &+ rhs.downloadedPackets
        )
    }

    private nonisolated static func positiveDifference(_ value: UInt64, _ previous: UInt64) -> UInt64 {
        value >= previous ? value - previous : 0
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

    private var runtimeProfile: NulConnectProfile {
        var profile = self.profile.normalizedForHITAuth()
        if !isHelperInstalled {
            profile.routeMode = .proxy
            profile.useSystemProxy = false
        }
        return profile
    }
}
