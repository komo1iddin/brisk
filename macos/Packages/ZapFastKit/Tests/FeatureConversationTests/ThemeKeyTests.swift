import AppKit
import Testing
@testable import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI
@testable import FeatureConversation

/// The open chat compares its theme's key on every update; a key that
/// changed with nothing else rebuilt every row for each message that came
/// in, and so the new message never slid in.
@MainActor
struct ThemeKeyTests {
    @Test func theSameLookAlwaysHasTheSameKey() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-theme-key-\(UUID().uuidString)")
        let store = ThemeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, wallpapersFolder: folder)
        for preset in ThemePresets.all {
            let keys = Set((0..<20).map { _ in ChatTheme(preset.appearance, photos: store).key })
            #expect(keys.count == 1, "\(preset.id)")
        }
    }
}
