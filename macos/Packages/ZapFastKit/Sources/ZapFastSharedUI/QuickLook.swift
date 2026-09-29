import AppKit
import Quartz

/// Shows files in the system Quick Look panel: the same preview Finder
/// gives with Space, with its own zoom, markup, and "Open with" button.
public final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLook()

    private var items: [URL] = []

    /// Previews `urls`, starting at `index`. Toggles the panel off when the
    /// same single file is already showing, as Space does in Finder.
    public func show(_ urls: [URL], at index: Int = 0) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, items == urls {
            panel.orderOut(nil)
            return
        }
        items = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(index, max(0, urls.count - 1))
        panel.makeKeyAndOrderFront(nil)
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}
