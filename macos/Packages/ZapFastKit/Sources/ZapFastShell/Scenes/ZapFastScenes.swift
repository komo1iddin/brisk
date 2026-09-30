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

    private var menuBarIcon: Binding<Bool> {
        Binding(get: { model.preferences.menuBarIcon }, set: { model.preferences.menuBarIcon = $0 })
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

        MenuBarExtra(isInserted: menuBarIcon) {
            MenuBarMenu(model: model)
        } label: {
            // Never a chat's name or a count, so nothing shows while locked.
            Image(systemName: model.chats.unreadChatCount > 0 && !model.appLock.isLocked
                ? "message.badge.filled.fill" : "message")
                .accessibilityLabel("ZapFast")
        }
    }
}

/// The menu bar icon's menu, as upstream's tray menu: show the window,
/// lock, quit.
private struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open ZapFast") {
            NSApp.activate()
            openWindow(id: "main")
        }
        if model.appLock.isEnabled {
            Button("Lock ZapFast") { model.appLock.lock() }
                .disabled(model.appLock.isLocked)
        }
        Divider()
        Button("Quit ZapFast") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
