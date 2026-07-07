import AppKit
import Darwin
import SwiftUI

@MainActor
final class NulConnectAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var isTerminating = false

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
                .environmentObject(windowCoordinator)
                .onAppear {
                    appDelegate.model = model
                }
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentSize)

        Settings {
            NulConnectSettingsView()
                .environmentObject(model)
                .environmentObject(windowCoordinator)
        }

        MenuBarExtra {
            NulConnectMenuBarContent()
                .environmentObject(model)
                .environmentObject(windowCoordinator)
        } label: {
            Image(systemName: model.menuBarSystemImage)
        }
        .menuBarExtraStyle(.menu)
    }
}
