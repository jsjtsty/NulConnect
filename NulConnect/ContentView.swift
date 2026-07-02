import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if let bannerMessage = model.bannerMessage {
                        InfoBanner(text: bannerMessage)
                    }

                    statusCard
                    connectionCard
                    loginCard
                    proxyCard
                    profileCard
                    persistenceCard
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
        .background(Color.black.opacity(0.001))
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
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.09, blue: 0.12),
                Color(red: 0.11, green: 0.13, blue: 0.18),
                Color(red: 0.08, green: 0.10, blue: 0.14)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.cyan.opacity(0.14))
                .frame(width: 260, height: 260)
                .blur(radius: 50)
                .offset(x: 70, y: -40)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("NulConnect")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("轻量的 HIT 连接器，先把状态、配置和持久化跑稳。")
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(phase: model.connectionState.phase)
                Text(model.profile.routeMode.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(model.profile.routeMode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var statusCard: some View {
        SectionCard(title: "当前状态", systemImage: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledValue(label: "连接阶段", value: model.connectionState.phase.title)
                LabeledValue(label: "状态说明", value: model.connectionState.message ?? "暂无")
                LabeledValue(label: "系统代理", value: model.effectiveSystemProxyEnabled ? "已启用" : "未启用")
                LabeledValue(label: "代理状态", value: proxyStateText)
            }
        }
    }

    private var connectionCard: some View {
        SectionCard(title: "连接模式", systemImage: "switch.2") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("模式", selection: Binding(
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

                Toggle(
                    "使用系统代理",
                    isOn: Binding(
                        get: { model.profile.useSystemProxy },
                        set: { newValue in
                            model.replaceProfile { profile in
                                profile.useSystemProxy = profile.routeMode == .proxy ? newValue : false
                            }
                        }
                    )
                )
                .disabled(model.profile.routeMode == .tun)
                .opacity(model.profile.routeMode == .tun ? 0.45 : 1)

                Text(model.profile.routeMode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loginCard: some View {
        SectionCard(title: "HIT 登录", systemImage: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledValue(label: "登录状态", value: model.loginStateText)
                if let detail = model.loginStateDetailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.webLoginMethods.isEmpty {
                    Text(model.isLoginConfigurationReady ? "点击刷新会拉取当前服务器支持的 WebView 登录方式。当前只实现 HIT 的 CAS 和 OAuth2 流程。" : "请先填写上方的服务地址并保存，然后再刷新登录方式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("可用登录方式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.webLoginMethods) { method in
                            Button {
                                model.startWebLogin(using: method)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(method.authName.isEmpty ? method.authType : method.authName)
                                            .font(.body.weight(.medium))
                                        Text("\(method.loginDomain) · \(method.authType)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("刷新登录方式") {
                        model.refreshLoginMethods()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isLoginConfigurationReady)

                    Button("默认方式登录") {
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
                LabeledValue(label: "监听地址", value: model.proxyEndpointText)
                LabeledValue(label: "当前状态", value: proxyStateText)

                Text("代理模式会在本机启动一个监听器，浏览器或其他客户端可以直接指向这里。若后续接入系统代理，这里会成为系统代理的落点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("启动代理") {
                        model.startProxyMode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.proxyEndpointText.isEmpty)

                    Button("停止代理") {
                        model.stopProxyMode()
                    }
                    .buttonStyle(.bordered)
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

                Divider().opacity(0.18)

                HStack {
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
        SectionCard(title: "持久化", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledValue(label: "会话", value: sessionSummaryText)
                LabeledValue(label: "资源快照", value: resourceSummaryText)
                if let error = model.lastPersistenceErrorMessage {
                    Text("最近错误: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 12) {
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
}

private struct StatusPill: View {
    let phase: NulConnectConnectionPhase

    var body: some View {
        Text(phase.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .foregroundStyle(.white)
    }

    private var background: some ShapeStyle {
        switch phase {
        case .connected:
            Color.green.opacity(0.28)
        case .connecting, .disconnecting:
            Color.orange.opacity(0.28)
        case .failed:
            Color.red.opacity(0.28)
        case .disconnected:
            Color.white.opacity(0.10)
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
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            content
        }
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct InfoBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
        }
        .font(.subheadline)
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
            GridItem(.flexible(minimum: 160), spacing: 16),
            GridItem(.flexible(minimum: 160), spacing: 16)
        ], spacing: 14) {
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel.bootstrap())
}
