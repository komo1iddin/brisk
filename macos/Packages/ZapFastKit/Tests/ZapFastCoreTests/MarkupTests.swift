import Foundation
import Testing
@testable import ZapFastCore

struct MarkupTests {
    @Test func boldItalicStrikeAndCode() {
        let text = WhatsAppMarkup.attributed("a *b* _c_ ~d~ `e`")
        #expect(String(text.characters) == "a b c d e")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.strikethrough))
        #expect(intents.contains(.code))
    }

    @Test func delimitersInsideWordsStayLiteral() {
        let text = WhatsAppMarkup.attributed("2*3*4 and snake_case_name")
        #expect(String(text.characters) == "2*3*4 and snake_case_name")
    }

    @Test func linksAreDetected() {
        let text = WhatsAppMarkup.attributed("see https://zapfast.rocks now")
        #expect(text.runs.contains { $0.link?.host() == "zapfast.rocks" })
    }
}
