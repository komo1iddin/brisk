import Testing
import ZapFastBridge
@testable import FeatureConversation

/// A quote names the people its message mentions, as upstream's
/// `quote_mentions`: a group of privacy ids otherwise shows bare numbers.
struct QuotePreviewTests {
    @Test func aQuoteNamesTheMentionedPeople() {
        let quoted = QuotedMessage(
            id: "", sender: "a@s.whatsapp.net", senderName: nil, summary: "ask @167650256810092 first",
            mentions: [MentionInfo(user: "167650256810092", id: "4917663430455@s.whatsapp.net")]
        )
        let preview = QuotePreview.named(quoted, original: nil) { id in
            id == "4917663430455@s.whatsapp.net" ? "Ada" : id
        }
        #expect(preview.summary == "ask @Ada first")
    }

    @Test func aQuoteWithoutMentionsIsAsItCame() {
        let quoted = QuotedMessage(id: "", sender: "a@s.whatsapp.net", senderName: nil, summary: "hi @ all", mentions: [])
        #expect(QuotePreview.named(quoted, original: nil) { $0 }.summary == "hi @ all")
    }
}

struct ReceiptTimeTests {
    @Test func aZeroReceiptTimeIsUnknown() {
        #expect(known(0) == nil)
        #expect(known(-5) == nil)
        #expect(known(nil) == nil)
        #expect(known(1_800_000_000) == 1_800_000_000)
    }
}
