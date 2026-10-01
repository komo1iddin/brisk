import FeatureSettings
import SwiftUI
import ZapFastCore
import ZapFastSharedUI

/// The app's SwiftUI scenes: Settings, and the menu bar's commands. The
/// main window and chats' own windows are AppKit (`MainWindowController`,
/// `ChatWindowController`), made by the app delegate. The app target only
/// declares `@main` and hands its model here.
public struct ZapFastScenes: Scene {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        Settings {
            SettingsView(model: model)
        }
        .commands {
            SidebarCommands()
            ToolbarCommands()
            ZapFastCommands(model: model)
        }
    }
}
