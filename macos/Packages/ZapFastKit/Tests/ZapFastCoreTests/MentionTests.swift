import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct MentionTests {
    private let group = "g@g.us"
    private let mira = "15550001111@s.whatsapp.net"
    private let mirko = "15550002222@s.whatsapp.net"
    private let me = "15559990000@s.whatsapp.net"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-mentions-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([
            .me(id: me, lid: nil, name: "Me", about: nil),
            .chats(chats: [chat(group, kind: .group, participants: [mira, mirko, me]), chat("d@s.whatsapp.net", kind: .direct)]),
            .contacts(contacts: [
                ContactRecord(id: mira, fullName: "Mira Example", firstName: "Mira", pushName: nil),
                ContactRecord(id: mirko, fullName: nil, firstName: nil, pushName: "Mirko"),
            ]),
        ])
        return (model, backend)
    }

    private func chat(_ id: String, kind: ChatKind, participants: [String] = []) -> ChatSummary {
        ChatSummary(
            id: id, name: "Team", groupSubjectKnown: true, kind: kind, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: participants, readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )
    }

    private func candidate(_ model: AppModel, _ id: String) -> MentionCandidate {
        model.mentionCandidates(in: group, query: "").first { $0.id == id }!
    }

    // MARK: Candidates

    @Test func candidatesAreGroupMembersButUsByNameOrNumber() {
        let (model, _) = model()
        #expect(model.mentionCandidates(in: group, query: "").map(\.id) == [mira, mirko])
        #expect(model.mentionCandidates(in: group, query: "mir").map(\.name) == ["Mira Example", "~Mirko"])
        #expect(model.mentionCandidates(in: group, query: "EXAMPLE").map(\.id) == [mira])
        #expect(model.mentionCandidates(in: group, query: "2222").map(\.id) == [mirko])
        #expect(model.mentionCandidates(in: group, query: "zed").isEmpty)
        #expect(model.mentionCandidates(in: "d@s.whatsapp.net", query: "").isEmpty, "only groups")
    }

    // MARK: Sending

    @Test func pickedNamesGoOutAsTokensWithTheirIDs() {
        let (model, backend) = model()
        model.addMention(candidate(model, mira), in: group)
        model.composerText[group] = "hello @Mira Example, see you"

        model.sendText(in: group)

        #expect(backend.sent.last == .sendText(
            chat: group, text: "hello @15550001111, see you", quoting: nil, mentions: [mira]
        ))
        #expect(model.composerMentions[group] == nil)
    }

    @Test func aNameEditedAwayIsNotMentioned() {
        let (model, backend) = model()
        model.addMention(candidate(model, mira), in: group)
        model.composerText[group] = "hello @Miranda"

        model.sendText(in: group)

        #expect(backend.sent.last == .sendText(chat: group, text: "hello @Miranda", quoting: nil, mentions: []))
    }

    @Test func typedTokensOfMembersStillMention() {
        let (model, backend) = model()
        model.composerText[group] = "still @15550002222!"

        model.sendText(in: group)

        #expect(backend.sent.last == .sendText(chat: group, text: "still @15550002222!", quoting: nil, mentions: [mirko]))
    }

    @Test func aMentionOutsideTheMembersIsRefused() {
        let (model, _) = model()
        model.addMention(MentionCandidate(id: "x@s.whatsapp.net", name: "X", phone: nil), in: group)
        #expect(model.composerMentions[group] == nil)
    }

    @Test func mentionsPickedBeforeAnEditComeBackAfterIt() {
        let (model, backend) = model()
        model.addMention(candidate(model, mira), in: group)
        model.composerText[group] = "hi @Mira Example"
        let sent = MessageRecord(
            id: "m", chat: group, sender: me, senderName: nil, fromMe: true,
            timestamp: Int64(Date.now.timeIntervalSince1970) - 10, content: .text(text: "old", preview: nil),
            status: .delivered, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "old"
        )
        model.apply([.messages(chat: group, messages: [sent], older: false, complete: true)])

        model.startEditing(sent)
        #expect(model.composerMentions[group] == nil)
        model.addMention(candidate(model, mirko), in: group)
        model.composerText[group] = "new @~Mirko"
        model.sendText(in: group)

        #expect(backend.sent.last == .editText(chat: group, id: "m", text: "new @15550002222", mentions: [mirko]))
        #expect(model.composerText[group] == "hi @Mira Example")
        #expect(model.composerMentions[group] == [ComposerMention(id: mira, name: "Mira Example")])
    }

    // MARK: Wire rules

    @Test func tokensDoNotMatchLongerNumbers() {
        #expect(MentionEncoding.containsToken("hi @12", user: "12"))
        #expect(!MentionEncoding.containsToken("hi @123", user: "12"))
        #expect(MentionEncoding.containsToken("@123 and @12.", user: "12"))
    }

    @Test func namesDoNotMatchLongerWords() {
        let text = "@Mira Examples and @Mira Example"
        let range = MentionEncoding.namedMention(in: text, token: "@Mira Example")
        #expect(range.map { text.distance(from: text.startIndex, to: $0.lowerBound) } == 19)
    }
}
