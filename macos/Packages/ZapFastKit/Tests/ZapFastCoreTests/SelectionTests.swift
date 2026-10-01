import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct SelectionTests {
    private let chat = "c@s.whatsapp.net"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-select-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.selectedChatID = chat
        let page = [
            message("a", at: 1), message("b", at: 2), message("gone", at: 3, content: .revoked),
            message("card", at: 4, content: .interactive(text: "Pick", card: nil)), message("e", at: 5),
        ]
        model.apply([.messages(chat: chat, messages: page, older: false, complete: true)])
        return (model, backend)
    }

    private func message(_ id: String, at time: Int64, content: MessageContent = .text(text: "hi", preview: nil)) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: time, content: content, status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "hi"
        )
    }

    private func record(_ model: AppModel, _ id: String) -> MessageRecord {
        model.conversations.conversation(chat).message(id)!
    }

    @Test func clicksKeepChatOrderAndTheLastOneOutEndsSelecting() {
        let (model, _) = model()
        model.select(record(model, "e"))
        model.toggleSelected(record(model, "a"))
        #expect(model.selection?.ids == ["a", "e"])
        model.toggleSelected(record(model, "a"))
        model.toggleSelected(record(model, "e"))
        #expect(model.selection == nil)
    }

    @Test func aRangeLeavesOutWhatCannotBeActedOn() {
        let (model, _) = model()
        model.select(record(model, "a"))
        model.selectRange(to: record(model, "e"))
        #expect(model.selection?.ids == ["a", "b", "card", "e"])
        model.select(record(model, "gone"))
        #expect(model.selection?.ids.contains("gone") == false)
    }

    @Test func aDragPicksWhatItPassesOverAndLetsGoWhenItReturns() {
        let (model, _) = model()
        model.select(record(model, "a"))
        let sweep = model.beginSweep(from: record(model, "a"))!
        model.sweep(sweep, to: record(model, "e"))
        #expect(model.selection?.ids == ["a", "b", "card", "e"])
        // Back over the way it came: what it reached beyond is let go.
        model.sweep(sweep, to: record(model, "b"))
        #expect(model.selection?.ids == ["a", "b"])
        model.sweep(sweep, to: record(model, "a"))
        #expect(model.selection?.ids == ["a"])
    }

    @Test func aDragUpwardPicksToo() {
        let (model, _) = model()
        model.select(record(model, "e"))
        model.sweep(model.beginSweep(from: record(model, "e"))!, to: record(model, "b"))
        #expect(model.selection?.ids == ["b", "card", "e"])
    }

    @Test func aDragKeepsWhatWasPickedBefore() {
        let (model, _) = model()
        model.select(record(model, "e"))
        model.toggleSelected(record(model, "a"))
        let sweep = model.beginSweep(from: record(model, "a"))!
        model.sweep(sweep, to: record(model, "b"))
        #expect(model.selection?.ids == ["a", "b", "e"])
    }

    @Test func aDragFromAMessagePutBackTakesOutWhatItPasses() {
        let (model, _) = model()
        model.select(record(model, "a"))
        model.selectRange(to: record(model, "e"))
        // The press took "b" out; the drag takes out what it passes.
        model.toggleSelected(record(model, "b"))
        let sweep = model.beginSweep(from: record(model, "b"))!
        model.sweep(sweep, to: record(model, "card"))
        #expect(model.selection?.ids == ["a", "e"])
        model.sweep(sweep, to: record(model, "a"))
        #expect(model.selection?.ids == ["card", "e"])
        model.sweep(sweep, to: record(model, "b"))
        #expect(model.selection?.ids == ["a", "card", "e"])
    }

    @Test func aDragThatTakesOutTheLastOneEndsSelecting() {
        let (model, _) = model()
        model.select(record(model, "a"))
        model.toggleSelected(record(model, "b"))
        model.toggleSelected(record(model, "b"))
        let sweep = model.beginSweep(from: record(model, "b"))!
        model.sweep(sweep, to: record(model, "a"))
        #expect(model.selection == nil)
        // A press that left nothing picked has nothing to sweep.
        model.select(record(model, "a"))
        model.toggleSelected(record(model, "a"))
        #expect(model.beginSweep(from: record(model, "a")) == nil)
    }

    @Test func forwardingTakesWhatCanBeForwarded() {
        let (model, _) = model()
        model.select(record(model, "a"))
        model.selectRange(to: record(model, "e"))
        model.forwardSelection()
        #expect(model.forwarding?.messages == ["a", "b", "e"])
        #expect(model.selection == nil)
    }

    @Test func copyingOneMessageTakesItsTextAndEndsSelecting() {
        let (model, _) = model()
        model.select(record(model, "b"))
        var copied: String?
        model.copySelection { copied = $0 }
        #expect(copied == "hi")
        #expect(model.selection == nil)
    }

    @Test func copyingSeveralNamesWhoWroteEachAndWhen() {
        let (model, _) = model()
        model.select(record(model, "e"))
        model.toggleSelected(record(model, "a"))
        var copied: String?
        model.copySelection { copied = $0 }
        let lines = copied?.split(separator: "\n").map(String.init) ?? []
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasPrefix("[") && $0.hasSuffix(": hi") })
    }

    @Test func aTranscriptMarksWhatIsNotText() {
        let voice = MessageRecord(
            id: "v", chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false, timestamp: 1_790_000_000,
            content: .audio(media: .init(mime: "audio/ogg", size: 1, width: nil, height: nil, path: nil), seconds: 41, voiceNote: true, waveform: Data()),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: ""
        )
        let text = message("t", at: 1_790_000_060)
        let transcript = MessageTranscript.text(
            [voice, text], name: { _ in "Ada" }, mentionName: { $0 },
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(transcript == "[14:13, 21/09/2026] Ada: [voice message, 0:41]\n[14:14, 21/09/2026] Ada: hi")
    }

    @Test func sharingHandsOnFilesAndTheRestAsText() {
        let (model, _) = model()
        model.select(record(model, "a"))
        #expect(model.shareableSelection == SelectionShare(text: "hi", files: []))
        model.cancelSelection()
        #expect(model.shareableSelection.isEmpty)
    }

    @Test func deletingSendsEachAndOpeningAnotherChatLetsGo() {
        let (model, backend) = model()
        model.select(record(model, "a"))
        model.toggleSelected(record(model, "b"))
        model.deleteSelectionForMe()
        #expect(backend.sent.suffix(2) == [.deleteLocal(chat: chat, id: "a"), .deleteLocal(chat: chat, id: "b")])

        model.select(record(model, "a"))
        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.selection == nil)
    }
}
