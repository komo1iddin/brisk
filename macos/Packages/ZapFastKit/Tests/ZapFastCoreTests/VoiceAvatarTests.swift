import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct VoiceAvatarTests {
    @Test func voiceMessagesShowWhoRecordedThemUntilTurnedOff() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.voiceAvatars)
        preferences.voiceAvatars = false
        #expect(!Preferences(defaults: defaults).voiceAvatars)
    }
}
