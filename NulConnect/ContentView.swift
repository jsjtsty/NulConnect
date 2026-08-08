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
    private enum SettingsTab: Hashable {
        case service
        case connection
        case statistics
        case helper
        case about
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowCoordinator: NulConnectWindowCoordinator
    @State private var selectedRouteMode: NulConnectRouteMode = .proxy
    @State private var showingHelperInstallConfirmation = false
    @State private var showingHelperUninstallConfirmation = false
    @State private var showingLogoutConfirmation = false
    @State private var selectedTab: SettingsTab = .service
    @State private var serverHostDraft = ""
    @State private var serverPortDraft = ""
    @State private var localProxyPortDraft = ""
    @State private var userAgentDraft = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            serviceSettings
                .tabItem {
                    Label("服务", systemImage: "server.rack")
                }
                .tag(SettingsTab.service)

            connectionSettings
                .tabItem {
                    Label("连接", systemImage: "network")
                }
                .tag(SettingsTab.connection)

            statisticsSettings
                .tabItem {
                    Label("统计", systemImage: "chart.xyaxis.line")
                }
                .tag(SettingsTab.statistics)

            helperSettings
                .tabItem {
                    Label("特权组件", systemImage: "shield.lefthalf.filled")
                }
                .tag(SettingsTab.helper)

            aboutSettings
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .onAppear {
            selectedRouteMode = model.effectiveRouteMode
            syncPortalDrafts()
            syncLocalProxyDraft()
            syncUserAgentDraft()
            updateStatisticsVisibility(for: selectedTab)
        }
        .onDisappear {
            commitDrafts()
            model.setStatisticsVisible(false)
        }
        .onChange(of: selectedTab) { _, newValue in
            updateStatisticsVisibility(for: newValue)
        }
        .onChange(of: model.effectiveRouteMode) { _, newValue in
            if selectedRouteMode != newValue {
                selectedRouteMode = newValue
            }
        }
        .onChange(of: model.profile.serverHost) {
            syncPortalDrafts()
        }
        .onChange(of: model.profile.serverPort) {
            syncPortalDrafts()
        }
        .onChange(of: model.profile.localProxyPort) {
            syncLocalProxyDraft()
        }
        .onChange(of: model.profile.userAgent) {
            syncUserAgentDraft()
        }
        .background(
            NulConnectWindowAccessor { window in
                windowCoordinator.register(window: window, role: .settings)
            }
        )
        .confirmationDialog(
            "退出登录",
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button("断开连接并退出登录", role: .destructive) {
                model.logout()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出登录将停止当前连接，并删除本机保存的会话及 HIT Web 登录数据。")
        }
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
            Text("安装特权组件需要管理员权限，可能降低系统安全性，只有在你明确需要系统代理或 VPN 模式时才建议继续。")
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
            Text("这会移除系统中的特权组件、LaunchDaemon 和状态文件，卸载后系统代理与 VPN 模式需要重新安装才能使用。")
        }
    }

    private var helperSettings: some View {
        Form {
            Section("特权组件") {
                LabeledContent("已安装版本") {
                    Text(model.helperVersionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }
                LabeledContent("内置版本") {
                    Text(model.bundledHelperVersionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }

                SettingsActionRow(
                    title: "安装或更新特权组件",
                    subtitle: "安装特权组件以启用系统代理和 VPN 模式，非特殊情况不推荐安装。",
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
                    subtitle: "移除用于支持系统代理和 VPN 模式的辅助程序、启动项和本地状态文件。",
                    systemImage: "trash"
                ) {
                    showingHelperUninstallConfirmation = true
                }
                .disabled(!model.isHelperInstalled || model.isVPNConnectedOrConnecting)
            }
        }
        .formStyle(.grouped)
        .textSelection(.disabled)
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

            Section("账户") {
                if let summary = model.sessionSummary {
                    LabeledContent("账号") {
                        Text(summary.username)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }

                    SettingsActionRow(
                        title: "退出登录",
                        subtitle: "删除本机保存的登录会话、账户资源和 Web 登录数据。",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        role: .destructive
                    ) {
                        requestLogout()
                    }
                    .disabled(model.isLoggingOut)
                } else {
                    LabeledContent("账号") {
                        Text("未登录")
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }

                    SettingsActionRow(
                        title: "登录",
                        subtitle: "通过 HIT 统一身份认证登录到服务器。",
                        systemImage: "person.badge.key"
                    ) {
                        model.startWebLogin()
                    }
                    .disabled(!model.isLoginConfigurationReady || model.isLoggingOut)
                }
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
                        text: "VPN 模式会接管所有流量，可能导致未知问题，非特殊情况不建议使用此模式。",
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
                        text: "使用系统代理和 VPN 模式需要在“特权组件”页安装组件，非特殊情况不建议使用这些模式。"
                    )
                }
            }

            Section("本地代理") {
                PortTextField("监听端口", text: $localProxyPortDraft)
                    .onSubmit { commitLocalProxyPortDraft() }
                    .disabled(model.isProxyRunning || model.isProxyBusy || model.isTunnelRunning || model.isTunnelBusy)
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

    private var statisticsSettings: some View {
        NulConnectStatisticsSettingsView()
    }

    private var aboutSettings: some View {
        Form {
            Section("关于 NulConnect") {
                LabeledContent("版本号") {
                    Text(appVersionText)
                        .textSelection(.disabled)
                }
                LabeledContent("构建版本号") {
                    Text(appBuildText)
                        .textSelection(.disabled)
                }
                LabeledContent("版权信息") {
                    Text("Copyright (C) NulStudio 2014-2026")
                        .textSelection(.disabled)
                }
                LabeledContent("许可证") {
                    Text("GNU Affero General Public Licence v3.0")
                        .textSelection(.disabled)
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.disabled)
    }

    private func requestLogout() {
        if model.isVPNConnectedOrConnecting {
            showingLogoutConfirmation = true
        } else {
            model.logout()
        }
    }

    private func updateStatisticsVisibility(for tab: SettingsTab) {
        let isVisible: Bool
        switch tab {
        case .statistics:
            isVisible = true
        default:
            isVisible = false
        }
        model.setStatisticsVisible(isVisible)
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

private struct NulConnectStatisticsSettingsView: View {
    @EnvironmentObject private var trafficStore: NulConnectTrafficStore

    var body: some View {
        Form {
            Section("实时流量") {
                HStack(spacing: 28) {
                    trafficMetric(
                        title: "下载",
                        value: NulConnectTrafficFormatter.rate(
                            trafficStore.statistics.downloadBytesPerSecond
                        ),
                        systemImage: "arrow.down",
                        color: .blue
                    )
                    trafficMetric(
                        title: "上传",
                        value: NulConnectTrafficFormatter.rate(
                            trafficStore.statistics.uploadBytesPerSecond
                        ),
                        systemImage: "arrow.up",
                        color: .green
                    )
                }
                .padding(.vertical, 4)
            }

            Section("本次连接") {
                LabeledContent(
                    "已下载",
                    value: NulConnectTrafficFormatter.bytes(
                        trafficStore.statistics.counters.downloadedBytes
                    )
                )
                LabeledContent(
                    "已上传",
                    value: NulConnectTrafficFormatter.bytes(
                        trafficStore.statistics.counters.uploadedBytes
                    )
                )
                LabeledContent("连接时长", value: connectionDurationText)
            }
        }
        .formStyle(.grouped)
        .textSelection(.disabled)
    }

    private func trafficMetric(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionDurationText: String {
        guard trafficStore.statistics.connectionStartedAt != nil else {
            return "--"
        }
        let seconds = Int(trafficStore.statistics.connectionDuration)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

}

enum NulConnectTrafficFormatter {
    static func rate(_ value: Double) -> String {
        format(max(0, value), suffix: "/s")
    }

    static func bytes(_ value: UInt64) -> String {
        format(Double(value), suffix: "")
    }

    private static func format(_ value: Double, suffix: String) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var scaledValue = value
        var unitIndex = 0
        while scaledValue >= 1_024, unitIndex < units.count - 1 {
            scaledValue /= 1_024
            unitIndex += 1
        }

        let fractionDigits = unitIndex == 0 || scaledValue >= 100 ? 0 : 1
        return "\(scaledValue.formatted(.number.precision(.fractionLength(fractionDigits)))) \(units[unitIndex])\(suffix)"
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
    let model = AppModel.bootstrap()
    ContentView()
        .environmentObject(model)
        .environmentObject(model.trafficStore)
}

#Preview("Settings") {
    let model = AppModel.bootstrap()
    NulConnectSettingsView()
        .environmentObject(model)
        .environmentObject(model.trafficStore)
}
