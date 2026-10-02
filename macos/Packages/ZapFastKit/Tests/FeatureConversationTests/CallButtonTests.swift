import Foundation
import Testing
import ZapFastBridge
@testable import FeatureConversation
@testable import ZapFastCore

/// Which chats offer a call: a person's (not our own), and a group we are
/// still in; never a channel or a broadcast list.
@MainActor
struct CallButtonTests {
    private func chat(_ id: String, kind: ChatKind, left: Bool = false, channel: Bool = false) -> ChatSummary {
        ChatSummary(
            id: id, name: "Chat", groupSubjectKnown: true, kind: kind, lastActivity: 1, unread: 0,
            markedUnread: false, archived: false, pinned: false, pinnedAt: 0, mutedUntil: nil, last: nil,
            favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: left,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: channel, looksUnread: false, phone: nil
        )
    }

    private func model() -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-callbutton-\(UUID().uuidString)")
        return AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
    }

    @Test func peopleAndGroupsCanBeCalled() {
        let model = model()
        #expect(ChatDetailViewController.canCall(chat("p@s.whatsapp.net", kind: .direct), model: model))
        #expect(ChatDetailViewController.canCall(chat("g@g.us", kind: .group), model: model))
    }

    @Test func leftGroupsChannelsAndListsCannot() {
        let model = model()
        #expect(!ChatDetailViewController.canCall(chat("g@g.us", kind: .group, left: true), model: model))
        #expect(!ChatDetailViewController.canCall(chat("c@newsletter", kind: .broadcast, channel: true), model: model))
        #expect(!ChatDetailViewController.canCall(chat("b@broadcast", kind: .broadcast), model: model))
        #expect(!ChatDetailViewController.canCall(nil, model: model))
    }
}
