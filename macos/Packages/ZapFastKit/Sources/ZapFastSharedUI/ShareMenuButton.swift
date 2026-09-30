import AppKit
import SwiftUI

/// A button that opens the Mac's share menu under itself for items of
/// mixed kinds, text and files together, which `ShareLink` cannot take.
/// The items are read when it is clicked.
public struct ShareMenuButton<Label: View>: View {
    private let items: () -> [Any]
    private let label: Label
    @State private var anchor = ShareAnchor()

    public init(items: @escaping () -> [Any], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    public var body: some View {
        Button { anchor.show(items()) } label: { label }
            .background(ShareAnchorView(anchor: anchor))
    }
}

/// The view the share menu hangs from.
final class ShareAnchor {
    weak var view: NSView?

    func show(_ items: [Any]) {
        guard let view, !items.isEmpty else { return }
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
