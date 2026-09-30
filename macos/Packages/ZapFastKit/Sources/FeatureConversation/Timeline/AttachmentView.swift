import AppKit

/// What photos, videos and documents in a drawn bubble share: a click
/// opens, plays or downloads it; a downloaded file drags out as a copy,
/// under the name it was sent with, as `draggableAttachment` hands it
/// over; a right-click shows the message's menu.
class AttachmentView: NSView, NSDraggingSource {
    weak var cell: BubbleCell?
    var messageID: String?
    private var mouseDownAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// What shows under the pointer while the file is dragged, and where
    /// it starts, in this view's coordinates.
    var dragImage: NSImage? { nil }
    var dragFrame: CGRect { bounds }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-click selects messages; the cell handles it.
            cell?.mouseDown(with: event)
            return
        }
        mouseDownAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        mouseDownAt = nil
        startDragging(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownAt != nil, let id = messageID else { return }
        mouseDownAt = nil
        cell?.delegate?.activateAttachment(ofMessage: id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu(for: event)
    }

    private func startDragging(_ event: NSEvent) {
        guard let id = messageID, let file = cell?.delegate?.attachmentFile(ofMessage: id),
              let copy = AttachmentFiles.dragCopy(of: file.url, named: file.name) else { return }
        let item = NSDraggingItem(pasteboardWriter: copy as NSURL)
        item.setDraggingFrame(dragFrame, contents: dragImage ?? NSWorkspace.shared.icon(forFile: copy.path(percentEncoded: false)))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Text pieces in one 8-bit layer, each cut short with an ellipsis when
/// it has more lines than its rect holds (a card's two-line title).
nonisolated final class PiecesLayer: CALayer {
    nonisolated(unsafe) var pieces: [TextPiece] = []
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard !pieces.isEmpty else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        let pieces = pieces
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                for piece in pieces {
                    piece.draw(options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
                }
            }
        }
    }
}
