import FeatureSettings
import SwiftUI
import ZapFastCore

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
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            ZapFastCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
