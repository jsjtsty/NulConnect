import AppKit
import Combine
import Darwin
import SwiftUI

@MainActor
final class NulConnectAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false
    private let statusItemController = NulConnectStatusItemController()
    private var webLoginObservation: AnyCancellable?
    private var openWebLogin: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateNow
        }
        guard let model, model.requiresNetworkCleanupForTermination else {
            return .terminateNow
        }

        isTerminating = true
        Task { @MainActor in
            await model.prepareForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func configureStatusItem(
        model: AppModel,
        openDashboard: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void,
        openWebLogin: @escaping @MainActor () -> Void
    ) {
        let isNewModel = self.model !== model
        self.model = model
        self.openWebLogin = openWebLogin
        statusItemController.configure(
            model: model,
            openDashboard: openDashboard,
            openSettings: openSettings
        )
        if isNewModel {
            webLoginObservation = model.$webLoginSession
                .compactMap { $0?.id }
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.openWebLogin?()
                }
        }
    }
}

private struct NulConnectStatusItemInstaller: View {
    let appDelegate: NulConnectAppDelegate
    let model: AppModel
    let windowCoordinator: NulConnectWindowCoordinator

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appDelegate.configureStatusItem(
                    model: model,
                    openDashboard: {
                        if !windowCoordinator.activateForPresentation(role: .main) {
                            openWindow(id: "main")
                        }
                        windowCoordinator.updateVisibilityAfterPresentation()
                    },
                    openSettings: {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NSApp.activate(ignoringOtherApps: true)
                            windowCoordinator.updateVisibilityAfterPresentation()
                        }
                    },
                    openWebLogin: {
                        if !windowCoordinator.activateForPresentation(role: .webLogin) {
                            openWindow(id: "web-login")
                        }
                        windowCoordinator.updateVisibilityAfterPresentation()
                    }
                )
            }
    }
}

@main
struct NulConnectApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: NulConnectAppDelegate
    @StateObject private var model = AppModel.bootstrap()
    @StateObject private var windowCoordinator = NulConnectWindowCoordinator()

    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("NulConnect", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.trafficStore)
                .environmentObject(windowCoordinator)
                .background {
                    NulConnectStatusItemInstaller(
                        appDelegate: appDelegate,
                        model: model,
                        windowCoordinator: windowCoordinator
                    )
                }
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentSize)

        Settings {
            NulConnectSettingsView()
                .environmentObject(model)
                .environmentObject(model.trafficStore)
                .environmentObject(windowCoordinator)
        }

        Window("Web 登录", id: "web-login") {
            NulConnectWebLoginWindow()
                .environmentObject(model)
                .environmentObject(windowCoordinator)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)

    }
}
