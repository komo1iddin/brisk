import Foundation
import ServiceManagement

/// Opening ZapFast at login. As upstream's `autostart`, the system's own
/// record (here the login item in System Settings › General › Login
/// Items) is the only one; nothing is kept in preferences.
public enum LoginItem {
    public enum State: Equatable, Sendable {
        case off, on
        /// Registered, waiting for the person to allow it in System Settings.
        case needsApproval
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// Returns why it could not be changed, if it could not.
    public static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return String(localized: "Could not change the login item: \(error.localizedDescription)")
        }
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
