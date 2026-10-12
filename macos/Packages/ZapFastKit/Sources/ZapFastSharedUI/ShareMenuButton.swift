import AppKit
import SwiftUI

/// A button that opens the Mac's share menu under itself for items of
/// mixed kinds, text and files together, which `ShareLink` cannot take.
/// The items are read when it is clicked.
public struct ShareMenuButton<Label: View>: View {
    private let items: () -> [Any]
    private var loadingItems: (() async -> [Any])?
    @State private var loading = false
    private let label: Label
    @State private var anchor = ShareAnchor()

    public init(items: @escaping () -> [Any], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    public init(loadingItems: @escaping () async -> [Any], @ViewBuilder label: () -> Label) {
        self.items = { [] }
        self.loadingItems = loadingItems
        self.label = label()
    }

    public var body: some View {
        Button {
            if let loadingItems {
                loading = true
                Task { @MainActor in
                    let prepared = await loadingItems()
                    loading = false
                    anchor.show(prepared)
                }
            } else { anchor.show(items()) }
        } label: { label }
            .disabled(loading)
            .background(ShareAnchorView(anchor: anchor))
    }
}

/// The view the share menu hangs from.
final class ShareAnchor {
    weak var view: NSView?

    func show(_ items: [Any]) {
        guard let view, view.window?.isVisible == true, !items.isEmpty else { return }
        NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
