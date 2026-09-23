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
                    Label(NulConnectLocalization.text("Settings"), systemImage: "gearshape")
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
                Text(verbatim: model.connectionState.phase.title)
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
                DetailRow(title: NulConnectLocalization.text("Mode"), value: model.routePresentationModeTitle, symbol: "switch.2")
                DetailRow(title: NulConnectLocalization.text("Server"), value: serverDisplayText, symbol: "server.rack")
                DetailRow(title: NulConnectLocalization.text("Local Proxy"), value: model.proxyEndpointText, symbol: "dot.radiowaves.left.and.right") {
                    copyProxyEndpoint()
                }
            }
        }
        .groupBoxStyle(.automatic)
    }

    private var serverDisplayText: String {
        let host = model.profile.serverHost.isEmpty ? NulConnectLocalization.text("Server not configured") : model.profile.serverHost
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
            return isProxyBusy || (!isProxyRunning && !model.isLocalProxyPortValid)
        case .tun:
            return !model.isTunnelFeatureAvailable || isTunnelBusy
        }
    }

    private var primaryActionTitle: String {
        if model.effectiveRouteMode == .tun {
            if isTunnelRunning {
                return NulConnectLocalization.text("Disconnect")
            }
            return model.needsLoginForTunnel ? NulConnectLocalization.text("Log In & Connect") : NulConnectLocalization.text("Connect")
        }
        if isProxyRunning {
            return NulConnectLocalization.text("Disconnect")
        }
        return model.needsLoginForProxy ? NulConnectLocalization.text("Log In & Connect") : NulConnectLocalization.text("Connect")
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
                    Label(NulConnectLocalization.text("Service"), systemImage: "server.rack")
                }
                .tag(SettingsTab.service)

            connectionSettings
                .tabItem {
                    Label(NulConnectLocalization.text("Connect"), systemImage: "network")
                }
                .tag(SettingsTab.connection)

            statisticsSettings
                .tabItem {
                    Label(NulConnectLocalization.text("Statistics"), systemImage: "chart.xyaxis.line")
                }
                .tag(SettingsTab.statistics)

            helperSettings
                .tabItem {
                    Label(NulConnectLocalization.text("Privileged Component"), systemImage: "shield.lefthalf.filled")
                }
                .tag(SettingsTab.helper)

            aboutSettings
                .tabItem {
                    Label(NulConnectLocalization.text("About"), systemImage: "info.circle")
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
            NulConnectLocalization.text("Log Out"),
            isPresented: $showingLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(NulConnectLocalization.text("Disconnect and Log Out"), role: .destructive) {
                model.logout()
            }
            Button(NulConnectLocalization.text("Cancel"), role: .cancel) {}
        } message: {
            Text(NulConnectLocalization.text("Logging out will stop the current connection and delete the saved session and web login data."))
        }
        .confirmationDialog(
            NulConnectLocalization.text("Install Privileged Component"),
            isPresented: $showingHelperInstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(NulConnectLocalization.text("Continue Installation"), role: .destructive) {
                Task {
                    do {
                        try await model.ensureHelperInstalledOrUpToDate(reason: NulConnectLocalization.text("Installing privileged component"))
                    } catch {
                        // The model reports the operation result.
                    }
                }
            }
            Button(NulConnectLocalization.text("Cancel"), role: .cancel) {}
        } message: {
            Text(NulConnectLocalization.text("Installing the privileged component requires administrator access and may reduce system security. Continue only if you need system proxy or VPN mode."))
        }
        .confirmationDialog(
            NulConnectLocalization.text("Uninstall Privileged Component"),
            isPresented: $showingHelperUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button(NulConnectLocalization.text("Uninstall")) {
                model.uninstallHelper()
            }
            Button(NulConnectLocalization.text("Cancel"), role: .cancel) {}
        } message: {
            Text(NulConnectLocalization.text("This removes the privileged component, LaunchDaemon, and state files. Install it again to use system proxy or VPN mode."))
        }
    }

    private var helperSettings: some View {
        Form {
            Section(NulConnectLocalization.text("Privileged Component")) {
                LabeledContent(NulConnectLocalization.text("Installed Version")) {
                    Text(model.helperVersionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }
                LabeledContent(NulConnectLocalization.text("Bundled Version")) {
                    Text(model.bundledHelperVersionText)
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                }

                SettingsActionRow(
                    title: NulConnectLocalization.text("Install or Update Privileged Component"),
                    subtitle: NulConnectLocalization.text("Install the privileged component to enable system proxy and VPN mode. Installation is not recommended unless needed."),
                    systemImage: "arrow.down.circle.fill"
                ) {
                    showingHelperInstallConfirmation = true
                }
                .disabled(model.isHelperActivityBusy || model.isVPNConnectedOrConnecting)

                if model.isHelperActivityBusy {
                    Text(NulConnectLocalization.text("Keep this page open while authorization and startup finish."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsActionRow(
                    title: NulConnectLocalization.text("Uninstall Privileged Component"),
                    subtitle: NulConnectLocalization.text("Remove the helper, launch item, and local state files used for system proxy and VPN mode."),
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
            Section(NulConnectLocalization.text("VPN Portal")) {
                TextField(NulConnectLocalization.text("Server"), text: $serverHostDraft)
                    .onSubmit { commitServerHostDraft() }

                PortTextField(NulConnectLocalization.text("Port"), text: $serverPortDraft)
                    .onSubmit { commitServerPortDraft() }
            }

            Section(NulConnectLocalization.text("Account")) {
                if let summary = model.sessionSummary {
                    LabeledContent(NulConnectLocalization.text("Account")) {
                        Text(summary.username)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }

                    SettingsActionRow(
                        title: NulConnectLocalization.text("Log Out"),
                        subtitle: NulConnectLocalization.text("Delete the locally saved login session, account resources, and web login data."),
                        systemImage: "rectangle.portrait.and.arrow.right",
                        role: .destructive
                    ) {
                        requestLogout()
                    }
                    .disabled(model.isLoggingOut)
                } else {
                    LabeledContent(NulConnectLocalization.text("Account")) {
                        Text(NulConnectLocalization.text("Not logged in"))
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                    }

                    SettingsActionRow(
                        title: NulConnectLocalization.text("Log In"),
                        subtitle: NulConnectLocalization.text("Sign in to the server using single sign-on."),
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
            Section(NulConnectLocalization.text("Mode")) {
                Picker(selection: Binding<NulConnectRouteMode>(
                    get: { model.effectiveRouteModePreference },
                    set: { newValue in
                        applySelectedRouteMode(newValue)
                    }
                ), label: Text(NulConnectLocalization.text("Connection Mode"))
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
                        text: NulConnectLocalization.text("VPN mode routes all traffic and may cause unexpected issues. Use it only when needed."),
                        isDangerous: true
                    )
                }

                Toggle(isOn: Binding(
                    get: { model.effectiveSystemProxyPreference },
                    set: { newValue in
                        model.setSystemProxyEnabled(newValue)
                    }
                )) {
                    Text(NulConnectLocalization.text("Enable System Proxy"))
                        .foregroundStyle(model.effectiveSystemProxyPreference ? .red : .primary)
                }
                .tint(.red)
                .disabled(!model.canChangeSystemProxyPreference || model.isSystemProxyBusy || !model.isHelperInstalled)

                if (model.effectiveSystemProxyPreference) {
                    PrivilegedFeatureNotice(
                        systemImage: "network.badge.shield.half.filled",
                        text: NulConnectLocalization.text("System proxy mode may conflict with other proxy software. Use it only when needed."),
                        isDangerous: true
                    )
                }
                
                if !model.isHelperInstalled {
                    PrivilegedFeatureNotice(
                        systemImage: "lock.shield",
                        text: NulConnectLocalization.text("System proxy and VPN mode require the component on the Privileged Component tab. Use these modes only when needed.")
                    )
                }
            }

            Section(NulConnectLocalization.text("Local Proxy")) {
                PortTextField(NulConnectLocalization.text("Listening Port"), text: $localProxyPortDraft)
                    .onSubmit { commitLocalProxyPortDraft() }
                    .onChange(of: localProxyPortDraft) { _, _ in
                        commitLocalProxyPortDraft()
                    }
                    .disabled(model.isProxyRunning || model.isProxyBusy || model.isTunnelRunning || model.isTunnelBusy)
                if let localProxyPortError {
                    Label(localProxyPortError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section(NulConnectLocalization.text("Client Parameters")) {
                TextField("User-Agent", text: $userAgentDraft)
                    .onSubmit { commitUserAgentDraft() }

                Toggle(NulConnectLocalization.text("Allow Insecure TLS"), isOn: Binding(
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
            Section(NulConnectLocalization.text("About NulConnect")) {
                LabeledContent(NulConnectLocalization.text("Version")) {
                    Text(appVersionText)
                        .textSelection(.disabled)
                }
                LabeledContent(NulConnectLocalization.text("Build")) {
                    Text(appBuildText)
                        .textSelection(.disabled)
                }
                LabeledContent(NulConnectLocalization.text("Copyright")) {
                    Text("Copyright (C) NulStudio 2014-2026")
                        .textSelection(.disabled)
                }
                LabeledContent(NulConnectLocalization.text("License")) {
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
        return version?.isEmpty == false ? version ?? NulConnectLocalization.text("Unknown") : NulConnectLocalization.text("Unknown")
    }

    private var appBuildText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build?.isEmpty == false ? build ?? NulConnectLocalization.text("Unknown") : NulConnectLocalization.text("Unknown")
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
        guard model.profile.localProxyPort > 0 else {
            return
        }
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
        let value = localProxyPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localProxyPortError == nil, let parsed = UInt16(value), parsed > 0 else {
            model.replaceProfile { $0.localProxyPort = 0 }
            return
        }
        model.replaceProfile { $0.localProxyPort = parsed }
    }

    private var localProxyPortError: String? {
        let value = localProxyPortDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return NulConnectLocalization.text("Enter a local proxy port")
        }
        guard value.allSatisfy(\.isNumber) else {
            return NulConnectLocalization.text("Port must contain digits only")
        }
        guard let parsed = UInt32(value), (1...UInt32(UInt16.max)).contains(parsed) else {
            return NulConnectLocalization.text("Port must be between 1 and 65535")
        }
        return nil
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
            Section(NulConnectLocalization.text("Live Traffic")) {
                HStack(spacing: 28) {
                    trafficMetric(
                        title: NulConnectLocalization.text("Download"),
                        value: NulConnectTrafficFormatter.rate(
                            trafficStore.statistics.downloadBytesPerSecond
                        ),
                        systemImage: "arrow.down",
                        color: .blue
                    )
                    trafficMetric(
                        title: NulConnectLocalization.text("Upload"),
                        value: NulConnectTrafficFormatter.rate(
                            trafficStore.statistics.uploadBytesPerSecond
                        ),
                        systemImage: "arrow.up",
                        color: .green
                    )
                }
                .padding(.vertical, 4)
            }

            Section(NulConnectLocalization.text("This Connection")) {
                LabeledContent(
                    NulConnectLocalization.text("Downloaded"),
                    value: NulConnectTrafficFormatter.bytes(
                        trafficStore.statistics.counters.downloadedBytes
                    )
                )
                LabeledContent(
                    NulConnectLocalization.text("Uploaded"),
                    value: NulConnectTrafficFormatter.bytes(
                        trafficStore.statistics.counters.uploadedBytes
                    )
                )
                LabeledContent(NulConnectLocalization.text("Connection Duration"), value: connectionDurationText)
            }
        }
        .formStyle(.grouped)
        .textSelection(.disabled)
        .allowsHitTesting(false)
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
                .help(NulConnectLocalization.text("Copy"))
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
