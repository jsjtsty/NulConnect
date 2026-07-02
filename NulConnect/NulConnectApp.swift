import SwiftUI

@main
struct NulConnectApp: App {
    @StateObject private var model = AppModel.bootstrap()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 460, height: 520)
        .windowResizability(.contentSize)

        Settings {
            NulConnectSettingsView()
                .environmentObject(model)
        }
    }
}
