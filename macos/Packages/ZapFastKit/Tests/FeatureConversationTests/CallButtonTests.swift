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

    /// A model with calls, as a build with the `calls` feature makes, unless
    /// `calls` is nil: then the build decides, as the app's does.
    private func model(calls: CallService? = PreviewCallService()) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-callbutton-\(UUID().uuidString)")
        return AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            calls: calls
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

    /// Calls are in development: a build without the bridge's `calls`
    /// feature offers no call anywhere.
    @Test func aBuildWithoutCallsOffersNone() {
        let model = model(calls: nil)
        #expect(model.calls.isAvailable == callsSupported())
        if !callsSupported() {
            #expect(!ChatDetailViewController.canCall(chat("p@s.whatsapp.net", kind: .direct), model: model))
            #expect(!ChatDetailViewController.canCall(chat("g@g.us", kind: .group), model: model))
        }
    }
}
