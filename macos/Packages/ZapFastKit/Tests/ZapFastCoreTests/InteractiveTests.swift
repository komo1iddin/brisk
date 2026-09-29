import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct InteractiveTests {
    private let chat = "biz@s.whatsapp.net"

    private func model(connected: Bool = true, readOnly: Bool = false) -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-interactive-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [ChatSummary(
            id: chat, name: "Shop", groupSubjectKnown: true, kind: .direct, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: readOnly, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )])])
        if connected { model.apply([.link(state: .connected)]) }
        return (model, backend)
    }

    private func card(image: String? = nil, carousel: [String?] = []) -> InteractiveCardInfo {
        let media = { (path: String?) in MediaInfo(mime: "image/jpeg", size: 10, width: 10, height: 10, path: path) }
        return InteractiveCardInfo(
            body: "Pick one",
            buttons: [InteractiveButtonInfo(label: "Yes", url: nil, action: .reply)],
            image: image.map { _ in media(nil) },
            needsPhone: false,
            carousel: carousel.map { CarouselCardInfo(body: "", buttons: [], image: media($0), needsPhone: false, thumbnail: nil) },
            thumbnail: nil
        )
    }

    private func message(fromMe: Bool = false, edited: Bool = false, card: InteractiveCardInfo? = nil) -> MessageRecord {
        MessageRecord(
            id: "m", chat: chat, sender: chat, senderName: nil, fromMe: fromMe, timestamp: 1,
            content: .interactive(text: "Pick one\nYes", card: card ?? self.card()),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: edited,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Pick one"
        )
    }

    @Test func aReplySendsOnlyIndicesOnceAtATime() {
        let (model, backend) = model()
        let business = message()
        model.answer(business, button: 0)
        #expect(backend.sent.last == .replyInteractive(chat: chat, message: "m", button: 0, choice: nil))

        model.apply([.interactiveReplyState(chat: chat, message: "m", pending: true)])
        #expect(!model.canAnswer(business))
        #expect(model.answerProblem(business) == "Sending reply…")
        model.apply([.interactiveReplyState(chat: chat, message: "m", pending: false)])
        #expect(model.canAnswer(business))
    }

    @Test func upstreamsRulesTurnButtonsOff() {
        #expect(!model(connected: false).0.canAnswer(message()))
        #expect(!model(readOnly: true).0.canAnswer(message()))
        let (model, backend) = model()
        #expect(!model.canAnswer(message(fromMe: true)))
        #expect(!model.canAnswer(message(edited: true)))
        model.answer(message(fromMe: true), button: 0)
        #expect(!backend.sent.contains { if case .replyInteractive = $0 { true } else { false } })
    }

    @Test func aListChoiceGoesWithItsButton() {
        let (model, backend) = model()
        model.showChoices(message(), button: 1)
        #expect(model.interactiveList?.button == 1)
        model.answer(message(), button: 1, choice: 3)
        #expect(backend.sent.last == .replyInteractive(chat: chat, message: "m", button: 1, choice: 3))
        #expect(model.interactiveList == nil)
    }

    @Test func carouselImagesDownloadAndLandByCard() {
        let (model, backend) = model()
        model.apply([.messages(chat: chat, messages: [message(card: card(carousel: [nil, nil]))], older: false, complete: true)])
        let loaded = model.conversations.conversation(chat).message("m")!

        model.downloadCard(loaded, card: 1)
        #expect(backend.sent.last == .download(chat: chat, message: "m", card: 1))
        model.apply([.media(chat: chat, message: "m", card: 1, path: "/tmp/card1.jpg", error: nil)])

        let updated = model.conversations.conversation(chat).message("m")!
        #expect(updated.content.media(card: 1)?.path == "/tmp/card1.jpg")
        #expect(updated.content.media(card: 0)?.path == nil)
        #expect(model.conversations.cardDownloads.isEmpty)

        // A fresh copy from the archive keeps the card's file.
        model.apply([.messageUpdated(message: message(card: card(carousel: [nil, nil])))])
        #expect(model.conversations.conversation(chat).message("m")!.content.media(card: 1)?.path == "/tmp/card1.jpg")
    }
}
