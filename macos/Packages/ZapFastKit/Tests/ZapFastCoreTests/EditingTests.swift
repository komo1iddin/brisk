import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct EditingTests {
    private let chat = "c@g.us"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-editing-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func mine(
        _ id: String,
        _ text: String,
        secondsAgo: Int64 = 60,
        mentions: [MentionInfo] = []
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "me@s.whatsapp.net", senderName: nil,
            fromMe: true, timestamp: Int64(Date.now.timeIntervalSince1970) - secondsAgo,
            content: .text(text: text, preview: nil),
            status: .delivered, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: mentions, forwarded: false, thumbnail: nil, summary: text
        )
    }

    private func edits(_ backend: PreviewBackend) -> [BridgeCommand] {
        backend.sent.filter { if case .editText = $0 { true } else { false } }
    }

    @Test func onlyOwnTextMessagesInsideFifteenMinutesCanBeEdited() {
        let (model, _) = model()
        #expect(model.canEdit(mine("a", "hi", secondsAgo: 14 * 60)))
        #expect(!model.canEdit(mine("a", "hi", secondsAgo: 16 * 60)))

        var theirs = mine("b", "hi")
        theirs.fromMe = false
        #expect(!model.canEdit(theirs))
    }

    @Test func editingTakesTheComposerAndCancellingGivesItBack() {
        let (model, backend) = model()
        model.composerText[chat] = "half a thought"

        model.startEditing(mine("a", "old text"))
        #expect(model.composerText[chat] == "old text")

        model.cancelEditing(in: chat)
        #expect(model.composerText[chat] == "half a thought")
        #expect(model.editing[chat] == nil)
        #expect(edits(backend).isEmpty)
    }

    @Test func sendingAnEditKeepsMentionsStillInTheText() {
        let (model, backend) = model()
        let ana = MentionInfo(user: "111", id: "111@s.whatsapp.net")
        let bob = MentionInfo(user: "222", id: "222@s.whatsapp.net")
        model.startEditing(mine("a", "@111 and @222 come", mentions: [ana, bob]))

        model.composerText[chat] = "@111 come alone"
        model.sendText(in: chat)

        #expect(edits(backend) == [.editText(chat: chat, id: "a", text: "@111 come alone", mentions: ["111@s.whatsapp.net"])])
        #expect(model.editing[chat] == nil)
        #expect(model.composerText[chat] == "")
        // An edit is not a new message.
        #expect(!backend.sent.contains { if case .sendText = $0 { true } else { false } })
    }

    @Test func anUnchangedEditSendsNothing() {
        let (model, backend) = model()
        model.startEditing(mine("a", "same"))
        model.sendText(in: chat)
        #expect(edits(backend).isEmpty)
        #expect(model.editing[chat] == nil)
    }

    @Test func upArrowEditsTheNewestEditableMessage() {
        let (model, _) = model()
        model.apply([.messages(chat: chat, messages: [
            mine("old", "too late", secondsAgo: 20 * 60),
            mine("new", "fresh", secondsAgo: 30),
        ], older: false, complete: true)])

        #expect(model.editLastMessage(in: chat))
        #expect(model.editing[chat]?.id == "new")
    }

    @Test func replyingOrLeavingTheChatDropsAnEdit() {
        let (model, _) = model()
        model.selectedChatID = chat
        model.composerText[chat] = "draft"
        model.startEditing(mine("a", "old"))

        var theirs = mine("b", "question")
        theirs.fromMe = false
        model.reply(to: theirs)
        #expect(model.editing[chat] == nil)
        #expect(model.composerText[chat] == "draft")

        model.startEditing(mine("a", "old"))
        model.selectedChatID = "other@s.whatsapp.net"
        #expect(model.editing[chat] == nil)
        // What was typed before the edit is what stays as the draft.
        #expect(model.chats.drafts[chat] == "draft")
    }
}
