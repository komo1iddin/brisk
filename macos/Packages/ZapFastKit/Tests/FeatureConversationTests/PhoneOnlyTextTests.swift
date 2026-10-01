import Testing
import ZapFastBridge
@testable import FeatureConversation

struct PhoneOnlyTextTests {
    @Test func aViewOnceMessageSaysWhatItHolds() {
        func text(_ once: OnceMediaKind?) -> String {
            PhoneOnlyText.text(viewOnce: true, liveLocation: false, once: once)
        }
        #expect(text(.photo).hasPrefix("View once photo."))
        #expect(text(.video).hasPrefix("View once video."))
        #expect(text(.voice).hasPrefix("View once voice message."))
        #expect(text(.audio).hasPrefix("View once audio."))
        // Each kind says it opens only on the phone, and why.
        #expect(text(.photo).hasSuffix("For your privacy, it opens only on your phone."))
        // A bare placeholder knows only that it was view once.
        #expect(text(nil).hasPrefix("View once message."))
    }

    @Test func otherPhoneOnlyMessagesKeepTheirOwnLines() {
        #expect(PhoneOnlyText.text(viewOnce: false, liveLocation: true, once: nil).hasPrefix("Live location."))
        #expect(PhoneOnlyText.text(viewOnce: false, liveLocation: false, once: nil) == "This message is only on your phone.")
    }
}
