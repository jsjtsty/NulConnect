import AppKit
import Combine

@MainActor
private final class NulConnectTrafficMenuView: NSView {
    private let downloadValue = NSTextField(labelWithString: "0 B/s")
    private let uploadValue = NSTextField(labelWithString: "0 B/s")

    override var intrinsicContentSize: NSSize {
        NSSize(width: 196, height: 24)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let download = makeMetric(
            symbol: "arrow.down",
            color: .systemBlue,
            value: downloadValue
        )
        let upload = makeMetric(
            symbol: "arrow.up",
            color: .systemGreen,
            value: uploadValue
        )
        let metrics = NSStackView(views: [download, upload])
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 12
        metrics.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metrics)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 196),
            heightAnchor.constraint(equalToConstant: 24),
            metrics.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            metrics.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metrics.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ statistics: NulConnectTrafficStatistics) {
        downloadValue.stringValue = NulConnectTrafficFormatter.rate(
            statistics.downloadBytesPerSecond
        )
        uploadValue.stringValue = NulConnectTrafficFormatter.rate(
            statistics.uploadBytesPerSecond
        )
    }

    private func makeMetric(
        symbol: String,
        color: NSColor,
        value: NSTextField
    ) -> NSView {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = color
        imageView.setContentHuggingPriority(.required, for: .horizontal)

        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.lineBreakMode = .byClipping

        let metric = NSStackView(views: [imageView, value])
        metric.orientation = .horizontal
        metric.alignment = .centerY
        metric.spacing = 5
        return metric
    }
}

@MainActor
final class NulConnectStatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let trafficMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let trafficView = NulConnectTrafficMenuView(
        frame: NSRect(x: 0, y: 0, width: 196, height: 24)
    )
    private let dashboardMenuItem = NSMenuItem(title: "仪表板", action: nil, keyEquivalent: "0")
    private let connectionMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "r")
    private let settingsMenuItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: ",")
    private let quitMenuItem = NSMenuItem(title: "退出", action: nil, keyEquivalent: "q")

    private weak var model: AppModel?
    private var openDashboard: (() -> Void)?
    private var openSettings: (() -> Void)?
    private var modelObservation: AnyCancellable?
    private var trafficObservation: AnyCancellable?

    override init() {
        super.init()
        configureMenu()
    }

    func configure(
        model: AppModel,
        openDashboard: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.openDashboard = openDashboard
        self.openSettings = openSettings

        if self.model !== model {
            self.model = model
            model.setMenuBarVisible(true)
            observe(model)
        }

        refreshModelState()
        refreshTraffic(model.trafficStore.statistics)
    }

    private func configureMenu() {
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false
        trafficMenuItem.isEnabled = false
        trafficMenuItem.view = trafficView

        configureActionItem(
            dashboardMenuItem,
            action: #selector(showDashboard),
            systemImage: "rectangle.3.group",
            keyEquivalentModifierMask: .command
        )
        configureActionItem(
            connectionMenuItem,
            action: #selector(toggleConnection),
            systemImage: "play.fill",
            keyEquivalentModifierMask: .command
        )
        configureActionItem(
            settingsMenuItem,
            action: #selector(showSettings),
            systemImage: "gearshape",
            keyEquivalentModifierMask: .command
        )
        configureActionItem(
            quitMenuItem,
            action: #selector(quitApplication),
            systemImage: "power",
            keyEquivalentModifierMask: .command
        )

        menu.items = [
            statusMenuItem,
            trafficMenuItem,
            .separator(),
            dashboardMenuItem,
            connectionMenuItem,
            settingsMenuItem,
            .separator(),
            quitMenuItem,
        ]
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
    }

    private func configureActionItem(
        _ item: NSMenuItem,
        action: Selector,
        systemImage: String,
        keyEquivalentModifierMask: NSEvent.ModifierFlags = []
    ) {
        item.target = self
        item.action = action
        item.isEnabled = true
        item.keyEquivalentModifierMask = keyEquivalentModifierMask
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    }

    private func observe(_ model: AppModel) {
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshModelState()
            }
        }
        trafficObservation = model.trafficStore.$statistics.sink { [weak self] statistics in
            self?.refreshTraffic(statistics)
        }
    }

    private func refreshModelState() {
        guard let model else { return }

        let host = model.profile.serverHost.isEmpty ? "未配置服务器" : model.profile.serverHost
        statusMenuItem.title = "\(model.connectionState.phase.title) · \(host)"

        let isRunning = selectedModeIsRunning(model)
        trafficMenuItem.isHidden = !(model.isProxyRunning || model.isTunnelRunning)
        connectionMenuItem.title = connectionActionTitle(model, isRunning: isRunning)
        connectionMenuItem.image = NSImage(
            systemSymbolName: isRunning ? "stop.fill" : "play.fill",
            accessibilityDescription: nil
        )
        connectionMenuItem.isEnabled = !(
            model.isProxyBusy
                || model.isTunnelBusy
                || model.isSystemProxyBusy
                || isLoginBusy(model.loginState)
        )

        let image = NSImage(
            systemSymbolName: model.menuBarSystemImage,
            accessibilityDescription: "NulConnect"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func refreshTraffic(_ statistics: NulConnectTrafficStatistics) {
        trafficView.update(statistics)
    }

    private func selectedModeIsRunning(_ model: AppModel) -> Bool {
        switch model.effectiveRouteMode {
        case .proxy:
            return model.isProxyRunning
        case .tun:
            return model.isTunnelRunning
        }
    }

    private func connectionActionTitle(_ model: AppModel, isRunning: Bool) -> String {
        switch model.effectiveRouteMode {
        case .proxy:
            return isRunning ? "停止代理" : "启动代理"
        case .tun:
            return isRunning ? "停止 VPN" : "启动 VPN"
        }
    }

    private func isLoginBusy(_ state: NulConnectLoginState) -> Bool {
        switch state {
        case .loadingMethods, .presenting, .finalizing:
            return true
        case .idle, .ready, .failed, .succeeded:
            return false
        }
    }

    @objc private func showDashboard() {
        openDashboard?()
    }

    @objc private func toggleConnection() {
        guard let model else { return }
        switch model.effectiveRouteMode {
        case .proxy:
            model.isProxyRunning ? model.stopProxyMode() : model.startProxyMode()
        case .tun:
            model.isTunnelRunning ? model.stopTunnelMode() : model.startTunnelMode()
        }
    }

    @objc private func showSettings() {
        openSettings?()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}
