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

    @Test func forwardingTakesWhatCanBeForwarded() {
        let (model, _) = model()
        model.select(record(model, "a"))
        model.selectRange(to: record(model, "e"))
        model.forwardSelection()
        #expect(model.forwarding?.messages == ["a", "b", "e"])
        #expect(model.selection == nil)
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
