import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsAdvancedSettings = false

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if let bannerMessage = model.bannerMessage {
                        InfoBanner(text: bannerMessage)
                    }

                    connectionOverview

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            loginCard
                            proxyCard
                        }

                        VStack(spacing: 16) {
                            loginCard
                            proxyCard
                        }
                    }

                    DisclosureGroup(isExpanded: $showsAdvancedSettings) {
                        VStack(spacing: 16) {
                            profileCard
                            persistenceCard
                        }
                        .padding(.top, 12)
                    } label: {
                        Label("高级设置与本地数据", systemImage: "slider.horizontal.3")
                            .font(.headline)
                    }
                    .padding(18)
                    .glassCard()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 980, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color(nsColor: .windowBackgroundColor).opacity(0.0),
                    Color.teal.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: 390, y: -250)

            Circle()
                .fill(Color.cyan.opacity(0.09))
                .frame(width: 300, height: 300)
                .blur(radius: 90)
                .offset(x: -360, y: 330)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("NulConnect")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("HIT aTrust 轻量连接器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            StatusPill(phase: model.connectionState.phase)
        }
    }

    private var connectionOverview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        StatusDot(phase: model.connectionState.phase)
                        Text(model.connectionState.phase.title)
                            .font(.title2.weight(.semibold))
                    }

                    Text(connectionSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let message = model.connectionState.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    Button(role: isProxyRunning ? .destructive : nil) {
                        performPrimaryConnectionAction()
                    } label: {
                        Label(primaryActionTitle, systemImage: primaryActionImage)
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(primaryActionTint)
                    .disabled(isPrimaryActionDisabled)

                    Text(primaryActionHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Picker("连接模式", selection: Binding(
                    get: { model.profile.routeMode },
                    set: { newValue in
                        model.replaceProfile { profile in
                            profile.routeMode = newValue
                            if newValue == .tun {
                                profile.useSystemProxy = false
                            }
                        }
                    }
                )) {
                    ForEach(NulConnectRouteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Label(model.profile.routeMode.subtitle, systemImage: model.profile.routeMode == .proxy ? "point.3.connected.trianglepath.dotted" : "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Toggle("系统代理", isOn: Binding(
                        get: { model.profile.useSystemProxy },
                        set: { newValue in
                            model.replaceProfile { profile in
                                profile.useSystemProxy = profile.routeMode == .proxy ? newValue : false
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.profile.routeMode == .tun)
                    .opacity(model.profile.routeMode == .tun ? 0.45 : 1)
                }
            }
        }
        .padding(22)
        .glassCard(prominence: .strong)
    }

    private var loginCard: some View {
        SectionCard(title: "HIT 登录", systemImage: "person.badge.key") {
            VStack(alignment: .leading, spacing: 14) {
                StatusRow(title: "登录状态", value: model.loginStateText, symbol: loginStateSymbol)

                if let detail = model.loginStateDetailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(loginDetailStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.webLoginMethods.isEmpty {
                    EmptyStateText(
                        text: model.isLoginConfigurationReady
                            ? "刷新后会显示当前服务器支持的 WebView 登录方式。当前只实现 HIT CAS / OAuth2 链路。"
                            : "请先填写服务地址，然后刷新登录方式。"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("可用方式")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        ForEach(model.webLoginMethods) { method in
                            Button {
                                model.startWebLogin(using: method)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe.asia.australia")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(method.authName.isEmpty ? method.authType : method.authName)
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(method.loginDomain) · \(method.authType)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("刷新登录方式") {
                        model.refreshLoginMethods()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isLoginConfigurationReady)

                    Button("默认登录") {
                        model.startWebLogin()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.webLoginMethods.isEmpty || !model.isLoginConfigurationReady)
                }
            }
        }
    }

    private var proxyCard: some View {
        SectionCard(title: "代理运行", systemImage: "network") {
            VStack(alignment: .leading, spacing: 14) {
                StatusRow(title: "监听地址", value: model.proxyEndpointText, symbol: "dot.radiowaves.left.and.right")
                StatusRow(title: "运行状态", value: proxyStateText, symbol: proxyStateSymbol)
                StatusRow(title: "系统代理", value: model.effectiveSystemProxyEnabled ? "已启用" : "未启用", symbol: "macwindow")

                EmptyStateText(text: "SOCKS5 / HTTP 代理会监听本机端口。默认只作为本地代理使用；开启系统代理后由系统转发。")

                HStack(spacing: 10) {
                    Button("启动代理") {
                        model.startProxyMode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.profile.routeMode != .proxy)

                    Button("停止代理") {
                        model.stopProxyMode()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProxyStopped)
                }
            }
        }
    }

    private var profileCard: some View {
        SectionCard(title: "服务配置", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 14) {
                TwoColumnGrid {
                    Field("VPN 门户地址") {
                        TextField("ivpn.hit.edu.cn", text: Binding(
                            get: { model.profile.serverHost },
                            set: { newValue in
                                model.replaceProfile { $0.serverHost = newValue }
                            }
                        ))
                    }

                    Field("端口") {
                        TextField("443", value: Binding(
                            get: { model.profile.serverPort },
                            set: { newValue in
                                model.replaceProfile { $0.serverPort = newValue }
                            }
                        ), format: .number)
                        .multilineTextAlignment(.trailing)
                    }

                    Field("登录域") {
                        TextField("cas93482", text: Binding(
                            get: { model.profile.loginDomain },
                            set: { newValue in
                                model.replaceProfile { $0.loginDomain = newValue }
                            }
                        ))
                    }

                    Field("首选认证") {
                        TextField("optional", text: Binding(
                            get: { model.profile.preferredAuthType ?? "" },
                            set: { newValue in
                                model.replaceProfile { $0.preferredAuthType = newValue.isEmpty ? nil : newValue }
                            }
                        ))
                    }

                    Field("User-Agent") {
                        TextField("NulConnect/1.0", text: Binding(
                            get: { model.profile.userAgent },
                            set: { newValue in
                                model.replaceProfile { $0.userAgent = newValue }
                            }
                        ))
                    }

                    Field("允许不安全 TLS") {
                        Toggle("", isOn: Binding(
                            get: { model.profile.allowInsecureTLS },
                            set: { newValue in
                                model.replaceProfile { $0.allowInsecureTLS = newValue }
                            }
                        ))
                        .labelsHidden()
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button("保存设置") {
                        model.saveProfileNow()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("恢复默认") {
                        model.resetProfileToDefaults()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var persistenceCard: some View {
        SectionCard(title: "本地数据", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                StatusRow(title: "会话", value: sessionSummaryText, symbol: "person.crop.circle.badge.checkmark")
                StatusRow(title: "资源快照", value: resourceSummaryText, symbol: "square.stack.3d.up")

                if let error = model.lastPersistenceErrorMessage {
                    Text("最近错误: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("重新载入") {
                        model.reloadPersistedState()
                    }
                    .buttonStyle(.bordered)

                    Button("清除会话") {
                        model.clearSessionMaterial()
                    }
                    .buttonStyle(.bordered)

                    Button("清除资源") {
                        model.clearResourceSnapshot()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var connectionSubtitle: String {
        let host = model.profile.serverHost.isEmpty ? "未配置服务器" : model.profile.serverHost
        return "\(host):\(model.profile.serverPort) · \(model.profile.routeMode.title)"
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

    private var isProxyStopped: Bool {
        if case .stopped = model.proxyState {
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
        model.profile.routeMode != .proxy || isProxyBusy
    }

    private var primaryActionTitle: String {
        if model.profile.routeMode == .tun {
            return "TUN 待接入"
        }
        return isProxyRunning ? "断开" : "连接"
    }

    private var primaryActionImage: String {
        if model.profile.routeMode == .tun {
            return "network"
        }
        return isProxyRunning ? "stop.fill" : "bolt.horizontal.fill"
    }

    private var primaryActionTint: Color {
        isProxyRunning ? .red : .accentColor
    }

    private var primaryActionHint: String {
        if model.profile.routeMode == .tun {
            return "当前界面先接入代理模式"
        }
        return isProxyRunning ? "停止本地代理监听" : "启动本地代理监听"
    }

    private var loginStateSymbol: String {
        switch model.loginState {
        case .failed:
            return "xmark.circle"
        case .succeeded:
            return "checkmark.seal"
        case .loadingMethods, .presenting, .finalizing:
            return "arrow.triangle.2.circlepath"
        default:
            return "person.crop.circle"
        }
    }

    private var loginDetailStyle: Color {
        switch model.loginState {
        case .failed:
            return .orange
        case .succeeded:
            return .green
        default:
            return .secondary
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
}

private struct StatusPill: View {
    let phase: NulConnectConnectionPhase

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(phase: phase)
            Text(phase.title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusDot: View {
    let phase: NulConnectConnectionPhase

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.45), radius: 4)
    }

    private var color: Color {
        switch phase {
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
}

private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            content
        }
        .padding(18)
        .glassCard()
    }
}

private struct InfoBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

private struct EmptyStateText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct TwoColumnGrid<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(minimum: 180), spacing: 16),
            GridItem(.flexible(minimum: 180), spacing: 16)
        ], spacing: 14) {
            content
        }
    }
}

private enum GlassCardProminence {
    case regular
    case strong
}

private struct GlassCardModifier: ViewModifier {
    let prominence: GlassCardProminence

    func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 24, x: 0, y: 14)
    }

    private var material: Material {
        switch prominence {
        case .regular:
            return .regularMaterial
        case .strong:
            return .thickMaterial
        }
    }

    private var cornerRadius: CGFloat {
        switch prominence {
        case .regular:
            return 18
        case .strong:
            return 24
        }
    }

    private var strokeOpacity: Double {
        switch prominence {
        case .regular:
            return 0.08
        case .strong:
            return 0.11
        }
    }

    private var shadowOpacity: Double {
        switch prominence {
        case .regular:
            return 0.045
        case .strong:
            return 0.07
        }
    }
}

private extension View {
    func glassCard(prominence: GlassCardProminence = .regular) -> some View {
        modifier(GlassCardModifier(prominence: prominence))
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel.bootstrap())
}
