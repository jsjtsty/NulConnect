import Foundation
import UserNotifications

/// Posts macOS notifications for connection events that happen while the
/// user is not looking at NulConnect (dropped VPN, expired sign-in, …).
/// macOS does not show them while the app is frontmost; the in-app banner
/// covers that case.
@MainActor
final class NulConnectNotifier {
    private var authorizationRequested = false
    private var isAuthorized = false

    func post(title: String, body: String, identifier: String) {
        Task { [weak self] in
            guard let self, await self.ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Reusing an identifier replaces the previous notification of the
            // same kind instead of stacking them (e.g. repeated reconnects).
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                NulConnectDiagnostics.log("[NulConnect][Notify] failed: \(error.localizedDescription)")
            }
        }
    }

    func clear(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func ensureAuthorized() async -> Bool {
        if authorizationRequested {
            return isAuthorized
        }
        authorizationRequested = true
        do {
            isAuthorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            NulConnectDiagnostics.log("[NulConnect][Notify] authorization failed: \(error.localizedDescription)")
            isAuthorized = false
        }
        return isAuthorized
    }
}
