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

                Text(connectionSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
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
                DetailRow(title: "模式", value: model.effectiveRouteMode.title, symbol: "switch.2")
                DetailRow(title: "本地代理", value: model.proxyEndpointText, symbol: "dot.radiowaves.left.and.right") {
                    copyProxyEndpoint()
                }
                DetailRow(title: "系统代理", value: "未开放", symbol: "macwindow")
                DetailRow(title: "运行状态", value: proxyStateText, symbol: proxyStateSymbol)
                }
            }
        .groupBoxStyle(.automatic)
    }

    private var connectionSubtitle: String {
        let host = model.profile.serverHost.isEmpty ? "未配置服务器" : model.profile.serverHost
        return "\(host):\(model.profile.serverPort)"
    }

    private var proxyStateText: String {
        switch model.proxyState {
        case .stopped:
            return "未启动"
        case .starting:
            return "启动中"
        case .running(let endpoint):
            return "运行中 · \(endpoint.displayString)"
        case .stopping:
            return "停止中"
        case .failed(let message):
            return "失败 · \(message)"
        }
    }

    private var isProxyRunning: Bool {
        if case .running = model.proxyState {
            return true
        }
        return false
    }

    private var isProxyBusy: Bool {
        switch model.proxyState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    private var isPrimaryActionDisabled: Bool {
        model.effectiveRouteMode != .proxy || isProxyBusy
    }

    private var primaryActionTitle: String {
        if model.effectiveRouteMode == .tun {
            return "TUN 模式待接入"
        }
        if isProxyRunning {
            return "断开连接"
        }
        return model.needsHITLoginForProxy ? "登录并连接" : "连接"
    }

    private var primaryActionImage: String {
        if model.effectiveRouteMode == .tun {
            return "network"
        }
        return isProxyRunning ? "stop.fill" : "power"
    }

    private var primaryActionTint: Color {
        isProxyRunning ? .red : .accentColor
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

    private var proxyStateSymbol: String {
        switch model.proxyState {
        case .running:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .starting, .stopping:
            return "arrow.triangle.2.circlepath"
        case .stopped:
            return "pause.circle"
        }
    }

    private func performPrimaryConnectionAction() {
        if isProxyRunning {
            model.stopProxyMode()
        } else {
            model.startProxyMode()
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

    var body: some View {
        TabView {
            serviceSettings
                .tabItem {
                    Label("服务", systemImage: "server.rack")
                }

            connectionSettings
                .tabItem {
                    Label("连接", systemImage: "network")
                }

            dataSettings
                .tabItem {
                    Label("数据", systemImage: "externaldrive")
                }

            aboutSettings
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .background(
            NulConnectWindowAccessor { window in
                windowCoordinator.register(window: window, role: .settings)
            }
        )
    }

    private var serviceSettings: some View {
        Form {
            Section("VPN 门户") {
                TextField("服务器", text: Binding(
                    get: { model.profile.serverHost },
                    set: { newValue in
                        model.replaceProfile { $0.serverHost = newValue }
                    }
                ))

                TextField("端口", value: Binding(
                    get: { model.profile.serverPort },
                    set: { newValue in
                        model.replaceProfile { $0.serverPort = newValue }
                    }
                ), format: .number)
            }

            Section("HIT Web 登录") {
                TextField("登录域", text: Binding(
                    get: { model.profile.loginDomain },
                    set: { newValue in
                        model.replaceProfile { $0.loginDomain = newValue }
                    }
                ))

                TextField("首选认证", text: Binding(
                    get: { model.profile.preferredAuthType ?? "" },
                    set: { newValue in
                        model.replaceProfile { $0.preferredAuthType = newValue.isEmpty ? nil : newValue }
                    }
                ))

                SettingsActionRow(
                    title: "重新登录",
                    subtitle: "打开 HIT WebView 并刷新会话与资源快照。",
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
                Picker("连接模式", selection: Binding(
                    get: { model.effectiveRouteMode },
                    set: { newValue in
                        model.replaceProfile { profile in
                            profile.routeMode = newValue == .tun ? .proxy : newValue
                            profile.useSystemProxy = false
                        }
                    }
                )) {
                    ForEach(NulConnectRouteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(true)

                Toggle("启用系统代理", isOn: Binding(
                    get: { false },
                    set: { newValue in
                        model.replaceProfile { profile in
                            profile.useSystemProxy = false
                        }
                    }
                ))
                .disabled(true)
            }

            Section("本地代理") {
                PortTextField("监听端口", port: Binding(
                    get: { model.profile.localProxyPort },
                    set: { newValue in
                        model.replaceProfile { $0.localProxyPort = newValue }
                    }
                ))
                .disabled(model.isProxyRunning)

                LabeledContent("代理地址", value: model.proxyEndpointText)
            }

            Section("客户端参数") {
                TextField("User-Agent", text: Binding(
                    get: { model.profile.userAgent },
                    set: { newValue in
                        model.replaceProfile { $0.userAgent = newValue }
                    }
                ))

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
}

struct NulConnectMenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowCoordinator: NulConnectWindowCoordinator
    @Environment(\.openWindow) private var openWindow

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
                if model.isProxyRunning {
                    model.stopProxyMode()
                } else {
                    model.startProxyMode()
                }
            }
            .disabled(model.profile.routeMode != .proxy || model.isProxyBusy)

            SettingsLink {
                Text("打开设置")
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
    @Binding var port: UInt16

    init(_ title: String, port: Binding<UInt16>) {
        self.title = title
        self._port = port
    }

    var body: some View {
        TextField(title, text: Binding(
            get: { String(port) },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                guard let parsed = UInt16(digits), parsed > 0 else {
                    return
                }
                port = parsed
            }
        ))
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
