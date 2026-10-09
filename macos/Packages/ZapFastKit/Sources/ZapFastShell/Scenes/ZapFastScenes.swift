import FeatureSettings
import SwiftUI
import ZapFastCore
import ZapFastSharedUI

/// The app's SwiftUI scenes: Settings, and the menu bar's commands. The
/// main window and chats' own windows are AppKit (`MainWindowController`,
/// `ChatWindowController`), made by the app delegate. The app target only
/// declares `@main` and hands its accounts here; both follow the account
/// in the window.
public struct ZapFastScenes: Scene {
    private let hub: AccountHub

    public init(hub: AccountHub) {
        self.hub = hub
    }

    public var body: some Scene {
        Settings {
            ActiveAccountSettings(hub: hub)
        }
        .commands {
            SidebarCommands()
            ToolbarCommands()
            ActiveAccountCommands(hub: hub)
        }
    }
}

/// Settings for the account in the window, made again when it changes.
private struct ActiveAccountSettings: View {
    let hub: AccountHub

    var body: some View {
        SettingsView(model: hub.active)
            .id(ObjectIdentifier(hub.active))
    }
}

private struct ActiveAccountCommands: Commands {
    let hub: AccountHub

    var body: some Commands {
        ZapFastCommands(model: hub.active)
    }
}
