import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct DocumentPreviewTests {
    private let group = "g@g.us"

    private func model(members: [String], connected: Bool = true) -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-names-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.chats(chats: [ChatSummary(
            id: group, name: "Group", groupSubjectKnown: true, kind: .group, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: members, readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil
        )])])
        if connected { model.apply([.link(state: .connected)]) }
        return (model, backend)
    }

    private func document(_ id: String, thumbnail: Data? = nil) -> MessageRecord {
        MessageRecord(
            id: id, chat: group, sender: "998901112233@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1_780_000_000, content: .document(
                media: MediaInfo(mime: "application/pdf", size: 1_000, width: nil, height: nil, path: nil),
                fileName: "a.pdf", caption: nil, pages: 1
            ),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: thumbnail, summary: "a.pdf"
        )
    }

    // MARK: Document previews

    @Test func aDocumentsPreviewIsAskedForOnceWhileConnected() {
        let (offline, offlineBackend) = model(members: [], connected: false)
        offline.fetchPreview(document("d1"))
        #expect(offlineBackend.sent.isEmpty, "asked again once the link is up")

        let (model, backend) = model(members: [])
        model.fetchPreview(document("d1"))
        model.fetchPreview(document("d1"))
        #expect(backend.sent == [.fetchPreview(chat: group, message: "d1")])
        // A sharp preview is here already.
        model.fetchPreview(document("d2", thumbnail: Data(count: AppModel.sharpPreviewBytes)))
        #expect(backend.sent.count == 1)
    }
}
