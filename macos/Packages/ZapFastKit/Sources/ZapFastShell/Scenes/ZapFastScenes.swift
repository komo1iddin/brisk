import FeatureSettings
import SwiftUI
import ZapFastCore
import ZapFastSharedUI

/// Every scene of the app. The app target only declares `@main` and hands
/// its model here.
public struct ZapFastScenes: Scene {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        // One linked session, so one main window.
        Window("ZapFast", id: "main") {
            RootView(model: model)
                .modifier(MainWindowOpener())
        }
        .defaultSize(width: 1100, height: 740)
        // Links (the Share menu's) come to the main window.
        .handlesExternalEvents(matching: ["share"])
        .commands {
            SidebarCommands()
            ToolbarCommands()
            ZapFastCommands(model: model)
        }

        // A chat in a window of its own, from its menu.
        WindowGroup("Chat", id: ChatWindowScene.id, for: String.self) { $chat in
            if let chat {
                ChatWindow(chatID: chat, model: model)
            }
        }
        .defaultSize(width: 520, height: 680)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView(model: model)
        }
    }
}
