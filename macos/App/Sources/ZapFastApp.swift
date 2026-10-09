import SwiftUI
import ZapFastShell

@main
struct ZapFastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        ZapFastScenes(hub: delegate.hub)
    }
}
