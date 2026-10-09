import AppKit
import Testing
import ZapFastDesign

/// The slim bar floats over the content. AppKit tiles a scroll view on every
/// frame of a scroll, and a tile that narrowed the content for the bar and
/// widened it again resized the document twice a frame: each resize put the
/// scroll back inside the content, so a chat pulled past its end jumped.
@MainActor
struct HoverScrollViewTests {
    private func scrollView() -> (HoverScrollView, NSView) {
        let scrollView = HoverScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3_000))
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        scrollView.tile()
        return (scrollView, document)
    }

    @Test func theContentKeepsTheFullWidth() {
        let (scrollView, document) = scrollView()
        #expect(scrollView.contentView.frame == scrollView.bounds)
        #expect(document.frame.width == 400)
    }

    @Test func tilingLeavesTheDocumentAlone() {
        let (scrollView, document) = scrollView()
        document.postsFrameChangedNotifications = true
        var resized: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: document, queue: nil
        ) { _ in
            MainActor.assumeIsolated { resized.append(document.frame.width) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<5 { scrollView.tile() }
        #expect(resized.isEmpty)
    }

    @Test func aResizedViewTakesTheNewWidth() {
        let (scrollView, document) = scrollView()
        scrollView.setFrameSize(NSSize(width: 520, height: 300))
        #expect(scrollView.contentView.frame.width == 520)
        #expect(document.frame.width == 520)
    }
}
