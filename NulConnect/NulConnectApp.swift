import AppKit
import SwiftUI

final class NulConnectAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct NulConnectApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: NulConnectAppDelegate
    @StateObject private var model = AppModel.bootstrap()
    @StateObject private var windowCoordinator = NulConnectWindowCoordinator()

    var body: some Scene {
        Window("NulConnect", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(windowCoordinator)
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
