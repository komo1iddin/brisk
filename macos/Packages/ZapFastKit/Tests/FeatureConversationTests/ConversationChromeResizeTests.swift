import AppKit
import Testing
import ZapFastBridge
@testable import ZapFastCore
@testable import FeatureConversation

@MainActor
@Suite(.serialized)
struct ConversationChromeResizeTests {
    private func fixture() -> (AppModel, ChatDetailViewController, NSWindow) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-chrome-resize-\(UUID())")
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder), preferences: preferences)
        model.selectedChatID = "synthetic"
        let detail = ChatDetailViewController(model: model, source: .selected)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = detail
        detail.view.layoutSubtreeIfNeeded()
        return (model, detail, window)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func hiddenWallpaperAndPlaceholderDoNotResizeButCatchUpWhenShown() async throws {
        let (model, detail, window) = fixture()
        defer { window.close() }
        let islands = detail.view.subviews.compactMap { $0 as? ResizeHostingView }
        let wallpaper = try #require(islands.first)
        let placeholder = try #require(islands.dropFirst().first)
        #expect(wallpaper.isHidden && placeholder.isHidden)
        let wallpaperFrame = wallpaper.frame, placeholderFrame = placeholder.frame
        window.setContentSize(CGSize(width: 900, height: 600))
        detail.view.layoutSubtreeIfNeeded()
        #expect(wallpaper.frame == wallpaperFrame && placeholder.frame == placeholderFrame)

        model.themes.set(ThemePresets.whatsApp, for: "synthetic")
        try await wait { !wallpaper.isHidden }
        detail.view.layoutSubtreeIfNeeded()
        #expect(wallpaper.frame == detail.view.bounds)
        model.themes.useDefault(for: "synthetic")
        try await wait { wallpaper.isHidden }

        model.selectedChatID = nil
        try await wait { !placeholder.isHidden }
        detail.view.layoutSubtreeIfNeeded()
        #expect(placeholder.frame.size == detail.view.bounds.size)
    }

    @Test func revealingAHiddenIslandSchedulesItsDeferredLayout() {
        let host = ResizeHostingView(layoutName: "PlaceholderLayout", passive: true)
        host.isHidden = true
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        host.needsLayout = false
        host.isHidden = false
        #expect(host.needsLayout)
        host.layoutSubtreeIfNeeded()
        #expect(!host.needsLayout)
        #expect(host.hitTest(.zero) == nil)
    }

    @Test func composerAndSearchUseTheirAppKitInsetsAcrossWidthChanges() throws {
        let (model, detail, window) = fixture()
        defer { window.close() }
        let pane = try #require(detail.children.first as? ConversationViewController)
        let islands = pane.view.subviews.compactMap { $0 as? ResizeHostingView }
        #expect(islands.count == 2 && islands.allSatisfy { $0.safeAreaRegions.isEmpty })
        let composer = try #require(islands.first)
        let height = composer.frame.height
        #expect(height > 0)
        window.setContentSize(CGSize(width: 900, height: 600))
        detail.view.layoutSubtreeIfNeeded()
        #expect(abs(composer.frame.height - height) < 0.5)
        #expect(composer.frame.maxY == pane.view.bounds.maxY)
        model.openChatSearch(in: "synthetic")
        detail.view.layoutSubtreeIfNeeded()
        #expect(composer.frame.maxY == pane.view.bounds.maxY)
    }
}
