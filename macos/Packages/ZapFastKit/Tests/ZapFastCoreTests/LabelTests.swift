import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct LabelTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-label-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func label(_ id: String, _ name: String) -> LabelInfo {
        LabelInfo(id: id, name: name, colorHex: "#3b82f6", createdAt: 1)
    }

    private func chat(_ id: String, labels: [String], channel: Bool = false, archived: Bool = false) -> ChatSummary {
        ChatSummary(
            id: id, name: id, groupSubjectKnown: true, kind: channel ? .broadcast : .direct, lastActivity: 1,
            unread: 0, markedUnread: false, archived: archived, pinned: false, pinnedAt: 0, mutedUntil: nil,
            last: nil, favorite: false, favoritePosition: 0, participants: [], readOnly: false, left: false,
            infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: labels,
            hasCustomSound: false, isChannel: channel, looksUnread: false, phone: nil
        )
    }

    @Test func aLabelListsItsChatsChannelsIncludedButNotArchived() {
        let (model, _) = model()
        model.apply([.chats(chats: [
            chat("a", labels: ["work"]),
            chat("news", labels: ["work"], channel: true),
            chat("old", labels: ["work"], archived: true),
            chat("b", labels: []),
        ])])
        let listed = model.chats.visibleChats(filter: .all, query: "", archived: false, label: "work").map(\.id)
        #expect(Set(listed) == ["a", "news"])
    }

    @Test func namesAreUniqueIgnoringCaseAndTheLimitHolds() {
        let (model, backend) = model()
        model.apply([.labels(labels: [label("1", "Work")])])
        model.createLabel(name: " work ", colorHex: "#22c55e")
        #expect(model.notices.last?.text == "A label named “work” already exists.")

        let many = (0..<Int(model.labelRules.limit)).map { label("\($0)", "L\($0)") }
        model.apply([.labels(labels: many)])
        model.createLabel(name: "One more", colorHex: "#22c55e")
        #expect(!backend.sent.contains { if case .createLabel = $0 { true } else { false } })
    }

    @Test func togglingALabelReplacesTheChatsWholeList() {
        let (model, backend) = model()
        let worn = chat("a", labels: ["1", "2"])
        model.toggleLabel("1", on: worn)
        model.toggleLabel("3", on: worn)
        #expect(backend.sent.suffix(2) == [
            .setChatLabels(chat: "a", labels: ["2"]),
            .setChatLabels(chat: "a", labels: ["1", "2", "3"]),
        ])
    }

    @Test func privateMeansOneToOne() {
        #expect(ChatFilter.direct.matches(chat("a", labels: [])))
        #expect(!ChatFilter.direct.matches(chat("news", labels: [], channel: true)))
    }
}
