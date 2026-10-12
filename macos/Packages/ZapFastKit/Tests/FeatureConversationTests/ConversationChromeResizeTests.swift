import AppKit
import SwiftUI
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
        let islands = Array(pane.view.subviews.compactMap { $0 as? ResizeHostingView }.suffix(2))
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

    @Test func emptyOverlayDefersResizeAndReturnsAtTheCurrentSize() async throws {
        let (model, detail, window) = fixture()
        defer { window.close() }
        let pane = try #require(detail.children.first as? ConversationViewController)
        let overlay = try #require(pane.view.subviews.compactMap { $0 as? ResizeHostingView }.first)
        let message = MessageRecord(id: "fixture", chat: "synthetic", sender: "sender", senderName: nil,
            fromMe: false, timestamp: 1, content: .text(text: "Synthetic fixture", preview: nil), status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false, mentions: [],
            forwarded: false, thumbnail: nil, summary: "")
        model.apply([.messages(chat: "synthetic", messages: [message], older: false, complete: true)])
        try await wait { overlay.isHidden }
        let before = overlay.frame
        window.setContentSize(CGSize(width: 900, height: 600))
        detail.view.layoutSubtreeIfNeeded()
        #expect(overlay.frame == before)
        model.apply([.chatCleared(chat: "synthetic", through: .max)])
        try await wait { !overlay.isHidden }
        detail.view.layoutSubtreeIfNeeded()
        #expect(overlay.frame.width == pane.view.bounds.width)
        let composer = try #require(pane.view.subviews.compactMap { $0 as? ResizeHostingView }.dropFirst().first)
        #expect(overlay.frame.maxY == composer.frame.minY)
        #expect(overlay.hitTest(.zero) == nil)
        model.apply([.messages(chat: "synthetic", messages: [message], older: false, complete: true)])
        try await wait { overlay.isHidden }
    }

    @Test func closedSearchDefersLayoutAndReopensAtTheResizedWidth() async throws {
        let (model, detail, window) = fixture()
        defer { window.close() }
        let pane = try #require(detail.children.first as? ConversationViewController)
        let search = try #require(pane.view.subviews.compactMap { $0 as? ResizeHostingView }.last)
        #expect(search.isHidden)
        window.setContentSize(CGSize(width: 1100, height: 600))
        detail.view.layoutSubtreeIfNeeded()
        model.openChatSearch(in: "synthetic")
        try await wait { !search.isHidden }
        detail.view.layoutSubtreeIfNeeded()
        #expect(search.frame.width == pane.view.bounds.width)
        #expect(search.frame.height > 0)
        #expect(search.frame.minY == pane.view.safeAreaInsets.top)
        model.closeChatSearch()
        try await wait { search.isHidden }
        model.openChatSearch(in: "synthetic")
        try await wait { !search.isHidden }
        detail.view.layoutSubtreeIfNeeded()
        #expect(search.frame.height > 0)
    }

    @Test func hostedRowsAndFixedOverlayUseTableAndPaneGeometry() throws {
        let cell = HostingCell(identifier: NSUserInterfaceItemIdentifier("fixture"))
        cell.show(Text("Synthetic hosted row"))
        let host = try #require(cell.subviews.first as? NSHostingView<AnyView>)
        #expect(host.safeAreaRegions.isEmpty && host.sizingOptions.isEmpty)
        for width in [CGFloat(300), 794, 1000] {
            cell.frame.size = CGSize(width: width, height: 100)
            #expect(host.frame == cell.bounds)
        }
        let (_, detail, window) = fixture()
        defer { window.close() }
        let pane = try #require(detail.children.first as? ConversationViewController)
        let newest = try #require(pane.view.subviews.compactMap { $0 as? IslandHostingView }.first)
        #expect(newest.safeAreaRegions.isEmpty)
        let size = newest.frame.size
        let trailing = pane.view.bounds.maxX - newest.frame.maxX
        window.setContentSize(CGSize(width: 1100, height: 600))
        detail.view.layoutSubtreeIfNeeded()
        #expect(newest.frame.size == size)
        #expect(pane.view.bounds.maxX - newest.frame.maxX == trailing)
    }

    @Test func chipResizeAndUnchangedBackingKeepTheirMeasuredText() throws {
        let chip = ChipCell(frame: CGRect(x: 0, y: 0, width: 400, height: 60))
        chip.large = true
        chip.configure(title: "Synthetic day", isHeader: true, colors: BubbleColors(.standard))
        let window = NSWindow(contentRect: chip.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chip
        defer { window.close() }
        chip.viewDidChangeBackingProperties()
        let drawing = try #require(chip.layer?.sublayers?.first)
        let text = try #require(drawing.sublayers?.first as? TextLayer)
        let height = chip.rowHeight
        text.displayIfNeeded()
        let shape = drawing.frame.size
        chip.frame.size.width = 900
        #expect(drawing.frame.size == shape && abs(drawing.frame.midX - 450) <= 0.5)
        #expect(chip.rowHeight == height && !text.needsDisplay())
        chip.viewDidChangeBackingProperties()
        #expect(!text.needsDisplay())
        text.contentsScale = window.backingScaleFactor / 2
        chip.viewDidChangeBackingProperties()
        #expect(text.contentsScale == window.backingScaleFactor && text.needsDisplay())
        text.displayIfNeeded()
        window.colorSpace = .adobeRGB1998
        chip.viewDidChangeBackingProperties()
        #expect(text.needsDisplay(), "A colour-space change still redraws at the same scale")
        chip.configure(title: "A much longer synthetic day label", isHeader: true, colors: BubbleColors(.standard))
        #expect(drawing.frame.width > shape.width)
    }
}
