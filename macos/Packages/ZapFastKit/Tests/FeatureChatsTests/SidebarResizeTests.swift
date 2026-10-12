import AppKit
import SwiftUI
import Testing
import ZapFastBridge
@testable import FeatureChats
@testable import ZapFastCore

@MainActor
@Suite(.serialized)
struct SidebarResizeTests {
    @Test func hiddenEmptyStateKeepsItsFrameAndCatchesUpWhenChatsDisappear() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-sidebar-resize-\(UUID())")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder),
                             preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let sidebar = SidebarViewController(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        defer { window.close() }
        sidebar.view.layoutSubtreeIfNeeded()
        let islands = sidebar.view.subviews.compactMap { $0 as? SidebarHostingView }
        let empty = try #require(islands.last)
        #expect(!empty.isHidden)
        let chat = ChatSummary(id: "synthetic", name: "Fixture", groupSubjectKnown: true, kind: .direct,
            lastActivity: 1, unread: 0, markedUnread: false, archived: false, pinned: false, pinnedAt: 0,
            mutedUntil: nil, last: nil, favorite: false, favoritePosition: 0, participants: [], readOnly: false,
            left: false, infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil, labels: [],
            hasCustomSound: false, isChannel: false, looksUnread: false, phone: nil)
        model.apply([.chats(chats: [chat])])
        try await wait { empty.isHidden }
        let before = empty.frame
        window.setContentSize(CGSize(width: 400, height: 600))
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(empty.frame == before)
        model.apply([.chatRemoved(chat: "synthetic")])
        try await wait { !empty.isHidden }
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(empty.frame.width == sidebar.view.bounds.width)
        #expect(empty.frame.maxY == sidebar.view.bounds.maxY)
        #expect(empty.hitTest(.zero) == nil)
    }

    @Test func revealingDeferredSearchSchedulesItsLayout() {
        let host = SidebarHostingView(layoutName: "SidebarResultsLayout")
        host.isHidden = true
        host.rootView = AnyView(Text("Synthetic results"))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        host.needsLayout = false
        host.isHidden = false
        #expect(host.needsLayout)
        host.layoutSubtreeIfNeeded()
        #expect(!host.needsLayout)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
}
