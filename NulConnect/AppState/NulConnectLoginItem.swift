import Foundation
import ServiceManagement

/// Registers NulConnect itself as a login item. Unlike a privileged daemon,
/// a main-app login item does not need a Developer ID signature.
enum NulConnectLoginItem {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    /// The user still has to allow the item in System Settings › General ›
    /// Login Items.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
