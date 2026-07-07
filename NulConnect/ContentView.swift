import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowCoordinator: NulConnectWindowCoordinator

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                connectionHeader
                primaryAction
                connectionDetails
            }
            .padding(24)
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            NulConnectWindowAccessor { window in
                windowCoordinator.register(window: window, role: .main)
            }
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        .sheet(item: $model.webLoginSession, onDismiss: {
            model.cancelWebLogin()
        }) { session in
            NulConnectWebLoginSheet(
                session: session,
                onCaptured: { callbackURL in
                    model.completeWebLogin(with: callbackURL)
                },
                onCancel: {
                    model.cancelWebLogin()
                }
            )
        }
    }

    private var connectionHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 88, height: 88)

                Circle()
                    .strokeBorder(statusColor.opacity(0.22), lineWidth: 1)
                    .frame(width: 88, height: 88)

                Image(systemName: statusSymbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            VStack(spacing: 4) {
                Text(model.connectionState.phase.title)
                    .font(.title2.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryAction: some View {
        Button(role: isProxyRunning ? .destructive : nil) {
            performPrimaryConnectionAction()
        } label: {
            Label(primaryActionTitle, systemImage: primaryActionImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(primaryActionTint)
        .disabled(isPrimaryActionDisabled)
        .keyboardShortcut(.defaultAction)
    }

    private var connectionDetails: some View {
        GroupBox {
            VStack(spacing: 10) {
                DetailRow(title: "模式", value: model.routePresentationModeTitle, symbol: "switch.2")
                DetailRow(title: "服务器", value: serverDisplayText, symbol: "server.rack")
                DetailRow(title: "本地代理", value: model.proxyEndpointText, symbol: "dot.radiowaves.left.and.right") {
                    copyProxyEndpoint()
                }
            }
        }
        .groupBoxStyle(.automatic)
    }

    private var serverDisplayText: String {
        let host = model.profile.serverHost.isEmpty ? "未配置服务器" : model.profile.serverHost
        return "\(host):\(model.profile.serverPort)"
    }

    private var isProxyRunning: Bool {
        if case .running = model.proxyState {
            return true
        }
        return false
    }

    private var isTunnelRunning: Bool {
        model.isTunnelRunning
    }

    private var isProxyBusy: Bool {
        switch model.proxyState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    private var isTunnelBusy: Bool {
        model.isTunnelBusy
    }

    private var isPrimaryActionDisabled: Bool {
        switch model.effectiveRouteMode {
        case .proxy:
            return isProxyBusy
        case .tun:
            return !model.isTunnelFeatureAvailable || isTunnelBusy
        }
    }

    private var primaryActionTitle: String {
        if model.effectiveRouteMode == .tun {
            if isTunnelRunning {
                return "断开连接"
            }
            return model.needsHITLoginForTunnel ? "登录并连接" : "连接"
        }
        if isProxyRunning {
            return "断开连接"
        }
        return model.needsHITLoginForProxy ? "登录并连接" : "连接"
    }

    private var primaryActionImage: String {
        if model.effectiveRouteMode == .tun {
            return isTunnelRunning ? "stop.fill" : "network"
        }
        return isProxyRunning ? "stop.fill" : "power"
    }

    private var primaryActionTint: Color {
        (isProxyRunning || isTunnelRunning) ? .red : .accentColor
    }

    private var statusColor: Color {
        switch model.connectionState.phase {
        case .connected:
            return .green
        case .connecting, .disconnecting:
            return .orange
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }

    private var statusSymbol: String {
        switch model.connectionState.phase {
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

    private func performPrimaryConnectionAction() {
        switch model.effectiveRouteMode {
        case .proxy:
            if isProxyRunning {
                model.stopProxyMode()
            } else {
                model.startProxyMode()
            }
        case .tun:
            if isTunnelRunning {
                model.stopTunnelMode()
            } else {
                model.startTunnelMode()
            }
        }
    }

    private func copyProxyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.proxyEndpointText, forType: .string)
    }
}

struct NulConnectSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowCoordinator: NulConnectWindowCoordinator
    @State private var selectedRouteMode: NulConnectRouteMode = .proxy
    @State private var showingHelperInstallConfirmation = false
    @State private var showingHelperUninstallConfirmation = false
    @State private var serverHostDraft = ""
    @State private var serverPortDraft = ""
    @State private var localProxyPortDraft = ""
    @State private var userAgentDraft = ""

    var body: some View {
        TabView {
            serviceSettings
                .tabItem {
                    Label("服务", systemImage: "slider.horizontal.3")
                }

            connectionSettings
                .tabItem {
                    Label("连接", systemImage: "network")
                }

            dataSettings
                .tabItem {
                    Label("数据", systemImage: "externaldrive.fill")
                }

            helperSettings
                .tabItem {
                    Label("特权组件", systemImage: "shield.lefthalf.filled")
                }

            aboutSettings
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .onAppear {
            selectedRouteMode = model.effectiveRouteMode
            syncPortalDrafts()
            syncLocalProxyDraft()
            syncUserAgentDraft()
        }
        .onDisappear { commitDrafts() }
        .onChange(of: model.effectiveRouteMode) { newValue in
            if selectedRouteMode != newValue {
                selectedRouteMode = newValue
            }
        }
        .onChange(of: model.profile.serverHost) { _ in
            syncPortalDrafts()
        }
        .onChange(of: model.profile.serverPort) { _ in
            syncPortalDrafts()
        }
        .onChange(of: model.profile.localProxyPort) { _ in
            syncLocalProxyDraft()
        }
        .onChange(of: model.profile.userAgent) { _ in
            syncUserAgentDraft()
        }
        .background(
            NulConnectWindowAccessor { window in
                windowCoordinator.register(window: window, role: .settings)
            }
        )
        .confirmationDialog(
            "安装特权组件",
            isPresented: $showingHelperInstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("继续安装", role: .destructive) {
                Task {
                    do {
                        try await model.ensureHelperInstalledOrUpToDate(reason: "正在安装特权组件")
                    } catch {
                        // 状态已由 model 处理
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("安装特权组件需要管理员权限，可能降低系统安全性，只有在你明确需要系统代理或 TUN 模式时才建议继续。")
        }
        .confirmationDialog(
            "卸载特权组件",
            isPresented: $showingHelperUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("卸载") {
                model.uninstallHelper()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除系统中的特权组件、LaunchDaemon 和状态文件，卸载后系统代理与 TUN 需要重新安装才能使用。")
        }
    }

    private var helperSettings: some View {
        Form {
            Section("特权组件") {
                LabeledContent("安装状态", value: model.isHelperInstalled ? "已安装" : "未安装")
                LabeledContent("已安装版本", value: model.helperVersionText)
                LabeledContent("内置版本", value: model.bundledHelperVersionText)

                SettingsActionRow(
                    title: "安装或更新特权组件",
                    subtitle: "安装特权组件以启用系统代理和 TUN 模式，非特殊情况不推荐安装。",
                    systemImage: "arrow.down.circle.fill"
                ) {
                    showingHelperInstallConfirmation = true
                }
                .disabled(model.isHelperActivityBusy || model.isVPNConnectedOrConnecting)

                if model.isHelperActivityBusy {
                    Text("安装过程中请保持此页可见，等待授权和启动完成。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsActionRow(
                    title: "卸载特权组件",
                    subtitle: "移除用于支持系统代理和 TUN 模式的辅助程序、启动项和本地状态文件。",
                    systemImage: "trash"
                ) {
                    showingHelperUninstallConfirmation = true
                }
                .disabled(!model.isHelperInstalled || model.isVPNConnectedOrConnecting)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshHelperVersion()
        }
    }

    private var serviceSettings: some View {
        Form {
            Section("VPN 门户") {
                TextField("服务器", text: $serverHostDraft)
                    .onSubmit { commitServerHostDraft() }

                PortTextField("端口", text: $serverPortDraft)
                    .onSubmit { commitServerPortDraft() }
            }

            Section("HIT Web 登录") {
                Picker("登录域", selection: loginDomainSelection) {
                    Text("自动").tag("")
                    ForEach(loginDomainOptions, id: \.self) { domain in
                        Text(domain).tag(domain)
                    }
                }
                .pickerStyle(.menu)

                Picker("首选认证", selection: preferredAuthTypeSelection) {
                    Text("自动").tag("")
                    ForEach(preferredAuthTypeOptions, id: \.authType) { method in
                        Text(preferredAuthTypeDisplayName(for: method)).tag(method.authType)
                    }
                }
                .pickerStyle(.menu)

                SettingsActionRow(
                    title: "重新登录",
                    subtitle: "通过 HIT 统一身份认证重新登录到服务器。",
                    systemImage: "person.badge.key"
                ) {
                    model.startWebLogin()
                }
                .disabled(!model.isLoginConfigurationReady)
            }
        }
        .formStyle(.grouped)
    }

    private var connectionSettings: some View {
        Form {
            Section("模式") {
                Picker(selection: Binding<NulConnectRouteMode>(
                    get: { model.effectiveRouteModePreference },
                    set: { newValue in
                        applySelectedRouteMode(newValue)
                    }
                ), label: Text("连接模式")
                    .foregroundStyle(model.effectiveRouteMode == .tun ? .red : .primary)) {
                    ForEach(NulConnectRouteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(model.effectiveRouteMode == .tun ? .red : .accentColor)
                .disabled(!model.isTunnelFeatureAvailable || !model.isHelperInstalled || model.isProxyRunning || model.isTunnelRunning || model.isProxyBusy || model.isTunnelBusy)

                if model.effectiveRouteMode == .tun {
                    PrivilegedFeatureNotice(
                        systemImage: "network.badge.shield.half.filled",
                        text: "TUN 模式会接管所有流量，可能导致未知问题，非特殊情况不建议使用此模式。",
                        isDangerous: true
                    )
                }

                Toggle(isOn: Binding(
                    get: { model.effectiveSystemProxyPreference },
                    set: { newValue in
                        model.setSystemProxyEnabled(newValue)
                    }
                )) {
                    Text("启用系统代理")
                        .foregroundStyle(model.effectiveSystemProxyPreference ? .red : .primary)
                }
                .tint(.red)
                .disabled(!model.canChangeSystemProxyPreference || model.isSystemProxyBusy || !model.isHelperInstalled)

                if (model.effectiveSystemProxyPreference) {
                    PrivilegedFeatureNotice(
                        systemImage: "network.badge.shield.half.filled",
                        text: "系统代理模式可能与其他代理软件发生冲突，非特殊情况不建议使用此模式。",
                        isDangerous: true
                    )
                }
                
                if !model.isHelperInstalled {
                    PrivilegedFeatureNotice(
                        systemImage: "lock.shield",
                        text: "使用系统代理和 TUN 模式需要在“特权组件”页安装组件，非特殊情况不建议使用这些模式。"
                    )
                }
            }

            Section("本地代理") {
                PortTextField("监听端口", text: $localProxyPortDraft)
                    .onSubmit { commitLocalProxyPortDraft() }
                    .disabled(model.isProxyRunning || model.isProxyBusy || model.isTunnelRunning || model.isTunnelBusy)

                HStack(spacing: 12) {
                    Text("代理地址")

                    Spacer(minLength: 12)

                    Text(model.proxyEndpointText)
                        .foregroundStyle(.primary)
                }
                // .font(.subheadline)
                .help("系统代理会指向这个本地代理地址，启用时需要管理员权限")
            }

            Section("客户端参数") {
                TextField("User-Agent", text: $userAgentDraft)
                    .onSubmit { commitUserAgentDraft() }

                Toggle("允许不安全 TLS", isOn: Binding(
                    get: { model.profile.allowInsecureTLS },
                    set: { newValue in
                        model.replaceProfile { $0.allowInsecureTLS = newValue }
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }

    private func applySelectedRouteMode(_ newValue: NulConnectRouteMode) {
        guard model.isHelperInstalled else {
            model.replaceProfile { profile in
                profile.routeMode = .proxy
                profile.useSystemProxy = false
            }
            selectedRouteMode = .proxy
            return
        }
        guard !model.isVPNConnectedOrConnecting else {
            selectedRouteMode = model.effectiveRouteMode
            return
        }
        DispatchQueue.main.async {
            model.replaceProfile { profile in
                if newValue == .tun && !model.canUseTunnelMode {
                    profile.routeMode = .proxy
                } else {
                    profile.routeMode = newValue
                }
                profile.useSystemProxy = false
            }
            selectedRouteMode = model.effectiveRouteMode
        }
    }

    private var dataSettings: some View {
        Form {
            Section("持久化") {
                LabeledContent("会话", value: sessionSummaryText)
                LabeledContent("资源快照", value: resourceSummaryText)

                if let error = model.lastPersistenceErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                SettingsActionRow(
                    title: "重新载入",
                    subtitle: "从本地存储重新读取配置、会话和资源快照。",
                    systemImage: "arrow.clockwise"
                ) {
                    model.reloadPersistedState()
                }

                SettingsActionRow(
                    title: "清除会话",
                    subtitle: "删除保存的登录会话，下次连接需要重新登录。",
                    systemImage: "person.crop.circle.badge.xmark",
                    role: .destructive
                ) {
                    model.clearSessionMaterial()
                }

                SettingsActionRow(
                    title: "清除资源",
                    subtitle: "删除本地资源快照，下次登录后会重新获取。",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    model.clearResourceSnapshot()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutSettings: some View {
        Form {
            Section("关于 NulConnect") {
                LabeledContent("版本号", value: appVersionText)
                LabeledContent("构建版本号", value: appBuildText)
                LabeledContent("版权信息", value: "Copyright (C) NulStudio 2014-2026")
                LabeledContent("许可证", value: "GNU Affero General Public Licence v3.0")
            }
        }
        .formStyle(.grouped)
    }

    private var sessionSummaryText: String {
        guard let summary = model.sessionSummary else {
            return "未保存"
        }
        return "\(summary.username) · \(summary.deviceID) · \(summary.cookieCount) 个 Cookie"
    }

    private var resourceSummaryText: String {
        guard let snapshot = model.resourceSnapshot else {
            return "未载入"
        }
        return "\(snapshot.resourceBytes.count) 字节 · \(snapshot.ipResources.count) IP · \(snapshot.domainResources.count) 域名"
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version?.isEmpty == false ? version ?? "未知" : "未知"
    }

    private var appBuildText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build?.isEmpty == false ? build ?? "未知" : "未知"
    }

    private func syncPortalDrafts() {
        let serverHost = model.profile.serverHost
        let serverPort = String(model.profile.serverPort)
        if serverHostDraft != serverHost {
            serverHostDraft = serverHost
        }
        if serverPortDraft != serverPort {
            serverPortDraft = serverPort
        }
    }

    private func syncLocalProxyDraft() {
        let localProxyPort = String(model.profile.localProxyPort)
        if localProxyPortDraft != localProxyPort {
            localProxyPortDraft = localProxyPort
        }
    }

    private func syncUserAgentDraft() {
        let userAgent = model.profile.userAgent
        if userAgentDraft != userAgent {
            userAgentDraft = userAgent
        }
    }

    private func commitDrafts() {
        commitServerHostDraft()
        commitServerPortDraft()
        commitLocalProxyPortDraft()
        commitUserAgentDraft()
    }

    private func commitServerHostDraft() {
        model.replaceProfile { $0.serverHost = serverHostDraft }
    }

    private func commitServerPortDraft() {
        guard let parsed = UInt16(serverPortDraft.filter(\.isNumber)), parsed > 0 else {
            return
        }
        model.replaceProfile { $0.serverPort = parsed }
    }

    private func commitLocalProxyPortDraft() {
        guard let parsed = UInt16(localProxyPortDraft.filter(\.isNumber)), parsed > 0 else {
            return
        }
        model.replaceProfile { $0.localProxyPort = parsed }
    }

    private func commitUserAgentDraft() {
        model.replaceProfile { $0.userAgent = userAgentDraft }
    }

    private var loginDomainSelection: Binding<String> {
        Binding(
            get: { model.profile.loginDomain },
            set: { newValue in
                model.replaceProfile { $0.loginDomain = newValue }
            }
        )
    }

    private var preferredAuthTypeSelection: Binding<String> {
        Binding(
            get: { model.profile.preferredAuthType ?? "" },
            set: { newValue in
                model.replaceProfile { $0.preferredAuthType = newValue.isEmpty ? nil : newValue }
            }
        )
    }

    private var loginDomainOptions: [String] {
        uniquePreservingOrder(model.availableLoginMethods.map(\.loginDomain))
    }

    private var preferredAuthTypeOptions: [ATRAuthMethod] {
        uniquePreservingOrder(model.availableLoginMethods, key: \.authType)
    }

    private func preferredAuthTypeDisplayName(for method: ATRAuthMethod) -> String {
        if method.authName.isEmpty {
            return method.authType
        }
        return "\(method.authName) · \(method.authType)"
    }

    private func uniquePreservingOrder<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private func uniquePreservingOrder<T, Key: Hashable>(_ values: [T], key: KeyPath<T, Key>) -> [T] {
        var seen = Set<Key>()
        return values.filter { seen.insert($0[keyPath: key]).inserted }
    }
}

struct NulConnectMenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowCoordinator: NulConnectWindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(menuStatusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("打开主界面") {
                if !windowCoordinator.activateForPresentation(role: .main) {
                    openWindow(id: "main")
                }
                windowCoordinator.updateVisibilityAfterPresentation()
            }

            Button(model.isProxyRunning ? "停止代理" : "启动代理") {
                switch model.effectiveRouteMode {
                case .proxy:
                    if model.isProxyRunning {
                        model.stopProxyMode()
                    } else {
                        model.startProxyMode()
                    }
                case .tun:
                    if model.isTunnelRunning {
                        model.stopTunnelMode()
                    } else {
                        model.startTunnelMode()
                    }
                }
            }
            .disabled(model.isProxyBusy || model.isTunnelBusy || model.isSystemProxyBusy)

            Button("打开设置") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    windowCoordinator.updateVisibilityAfterPresentation()
                }
            }

            Divider()

            Button("退出") {
                NSApp.terminate(nil)
            }
        }
        .frame(width: 204, alignment: .leading)
        .padding(12)
    }

    private var menuStatusText: String {
        let phase = model.connectionState.phase.title
        let host = model.profile.serverHost.isEmpty ? "未配置服务器" : model.profile.serverHost
        return "\(phase) · \(host)"
    }

}

private struct PortTextField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        TextField(title, text: $text)
            .autocorrectionDisabled()
    }
}

private struct PrivilegedFeatureNotice: View {
    let systemImage: String
    let text: String
    var isDangerous: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(foregroundColor)
                .frame(width: 18, alignment: .center)

            Text(text)
                .font(.footnote)
                .foregroundStyle(foregroundColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var foregroundColor: Color {
        isDangerous ? .red : .secondary
    }
}

private struct DetailRow<ActionContent: View>: View {
    let title: String
    let value: String
    let symbol: String
    let action: (() -> Void)?
    let actionContent: ActionContent

    init(
        title: String,
        value: String,
        symbol: String,
        action: (() -> Void)? = nil,
        @ViewBuilder actionContent: () -> ActionContent = { EmptyView() }
    ) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.action = action
        self.actionContent = actionContent()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let action {
                Button(action: action) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制")
            } else {
                actionContent
            }
        }
        .font(.subheadline)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(iconStyle)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(titleStyle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var titleStyle: Color {
        role == .destructive ? .red : .primary
    }

    private var iconStyle: Color {
        role == .destructive ? .red : .secondary
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel.bootstrap())
}

#Preview("Settings") {
    NulConnectSettingsView()
        .environmentObject(AppModel.bootstrap())
}

#Preview("Menu Bar") {
    NulConnectMenuBarContent()
        .environmentObject(AppModel.bootstrap())
        .environmentObject(NulConnectWindowCoordinator())
}
