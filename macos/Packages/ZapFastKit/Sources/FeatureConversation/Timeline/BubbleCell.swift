import AppKit
import AVFoundation
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What a timeline cell asks of the table's controller.
@MainActor
protocol TimelineCellDelegate: AnyObject {
    func showQuote(ofMessage id: String)
    /// The sender's name or photo was clicked: their page, in a popover at
    /// `rect` of `view`.
    func showSender(ofMessage id: String, relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge)
    /// The message's context menu, with a Copy for `selection` when some of
    /// its text is selected.
    func menu(forMessage id: String, selection: String?) -> NSMenu?
    /// Clicking a reaction's pill adds ours, or takes ours away (upstream's).
    func toggleReaction(_ emoji: String, ofMessage id: String)
    /// Who chose `emoji`, for its pill's tooltip.
    func reactionNames(_ emoji: String, ofMessage id: String) -> String
    /// A click on no message, beside one or below them all: the composer
    /// takes the keys again (upstream #283).
    func clickedBesideMessages()
    func open(_ url: URL)
    /// The pointer is over a message's text: it becomes selectable.
    func bodyHovered(in cell: BubbleCell)
    func bodyTextBecameActive(_ view: BodyTextView)
    /// ⌘-click: start selecting messages with this one.
    func startSelecting(fromMessage id: String)
    /// Reply and React, shown beside the bubble while the pointer is on the row.
    func hoverActions(forMessage id: String) -> NSView?
    func isPickingReaction(forMessage id: String) -> Bool
    func reactionPicker(forMessage id: String) -> NSViewController?
    func reactionPickerClosed(forMessage id: String)
    func accessibilityActions(forMessage id: String) -> [NSAccessibilityCustomAction]

    // Attachments. The cell reads these under observation, so each must
    // read only its own message's state.
    /// The attachment's download, while its file is not here.
    func downloadState(forMessage id: String) -> DownloadState?
    /// Whether the message's video is the one playing in place.
    func isPlayingInPlace(_ id: String) -> Bool
    var inlinePlayer: AVPlayer? { get }
    /// A click on the attachment: open, play, or download it.
    func activateAttachment(ofMessage id: String)
    /// The attachment came on screen (downloads start), or left it (a
    /// video playing in place pauses).
    func attachmentShown(inMessage id: String)
    func attachmentHidden(inMessage id: String)
    /// The downloaded file and the name to give it when dragged out.
    func attachmentFile(ofMessage id: String) -> (url: URL, name: String)?

    /// The sender's photo and its version, beside a run's last message in
    /// a group.
    func senderAvatar(forMessage id: String) -> AvatarSource

    // Voice messages.
    func voiceState(forMessage id: String) -> VoiceState
    /// The recorder's photo and its version, for the player's side.
    func recorderAvatar(forMessage id: String) -> AvatarSource
    func playVoice(inMessage id: String)
    func seekVoice(inMessage id: String, to fraction: Double)
    func cycleVoiceSpeed()

    // Picking messages.
    /// Read under observation, as the attachments' state.
    func selectionState(forMessage id: String) -> SelectionState
    /// A click while picking: in or out, or with Shift everything from the
    /// last click.
    func toggleSelection(ofMessage id: String, range: Bool)
    /// A press on the row that may turn into a drag across messages, which
    /// picks each one the pointer passes. Runs the drag; false, with nothing
    /// spent, when the press was a click.
    func sweep(fromMessage id: String, event: NSEvent) -> Bool
}

/// Whether messages are being picked, and this one's part in it.
struct SelectionState: Equatable {
    var selecting = false
    var selected = false
    /// A deleted message cannot be picked; its checkbox is faint.
    var enabled = true
}

/// Where a photo is and which version of it.
struct AvatarSource: Equatable {
    var url: URL?
    var version: Int
}

/// A message drawn by Core Animation instead of SwiftUI: text, a deleted
/// message's line, a photo, video or sticker.
///
/// Telefast's timeline measurements, repeated here: the bubble is a layer
/// background with rounded corners, composited by the GPU; only text is
/// rasterized, into 8-bit buffers (AppKit picks 16-bit ones on XDR displays,
/// which doubled the cost of every frame). The layout arrives measured, so
/// configuring a reused cell does no text layout at all.
///
/// Selecting text needs a text view, which costs far more than a layer, so
/// one is laid over the text only while the pointer is on it (or while it
/// keeps a selection), set up with the same string and width so nothing
/// moves when it appears.
final class BubbleCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineBubble")
    /// Cells with a picture, a file or a link's card are reused for the
    /// same, so each view is made once per cell.
    static func identifier(for layout: BubbleLayout) -> NSUserInterfaceItemIdentifier {
        if layout.picture != nil { return pictureIdentifier }
        if layout.document != nil { return documentIdentifier }
        if layout.linkPreview != nil { return linkIdentifier }
        if layout.voice != nil { return voiceIdentifier }
        return identifier
    }

    private static let voiceIdentifier = NSUserInterfaceItemIdentifier("TimelineBubble-voice")

    private static let pictureIdentifier = NSUserInterfaceItemIdentifier("TimelineBubble-picture")
    private static let documentIdentifier = NSUserInterfaceItemIdentifier("TimelineBubble-document")
    private static let linkIdentifier = NSUserInterfaceItemIdentifier("TimelineBubble-link")

    weak var delegate: TimelineCellDelegate?
    private(set) var messageID: String?
    private(set) var bubbleLayout: BubbleLayout?
    private let bubble = BubbleView()
    /// On a run's last message, the bubble's colour past its corner, under
    /// the bubble: the bubble's layer clips to its rounded corners.
    private let tail = CAShapeLayer()
    private let pills = ReactionPillsView()
    /// In a group, the sender's photo beside the last message of their run.
    private let avatar = AvatarLayers()
    private var highlighted = false
    /// The message's menu is open.
    private var menuOpen = false
    /// The bubble's shape, darkened, while its menu is open. A view of its
    /// own, not a loose sublayer: AppKit reorders a view's sublayers to
    /// match its subviews when one comes or goes (the hover buttons go as
    /// the menu opens), which put a loose layer behind the bubble.
    private var menuMark: PassiveLayerView?
    /// Reply and React beside the bubble, made once the pointer rests on
    /// the row: a row swept past while scrolling makes none.
    private var hoverActions: NSView?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false
    private var popover: NSPopover?
    /// Downloads and playback of the message's attachment.
    private var watches = CellWatches()
    private var selection = SelectionState()
    private let checkbox = SymbolLayer()
    /// Read out after the message: its download, or whether it is picked.
    private var downloadValue: String? {
        didSet { updateAccessibilityValue() }
    }
    /// The message the reaction picker opened for.
    private var popoverMessage: String?
    /// While picking, incoming bubbles move over for the checkboxes, as
    /// `MessageRow` offsets them.
    static let checkboxRoom: CGFloat = 28

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(bubble)
        addSubview(pills)
        tail.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "hidden": NSNull(), "fillColor": NSNull()]
        tail.isHidden = true
        layer?.insertSublayer(tail, below: bubble.layer)
        bubble.cell = self
        pills.cell = self
        checkbox.isHidden = true
        checkbox.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(checkbox)
        avatar.layer.isHidden = true
        layer?.addSublayer(avatar.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(id: String, layout: BubbleLayout, highlighted: Bool) {
        if id != messageID || layout !== bubbleLayout {
            if id != messageID {
                // A reused cell shows another message.
                if let messageID, bubbleLayout?.hasAttachment == true { delegate?.attachmentHidden(inMessage: messageID) }
                hideHoverActions(animated: false)
                popover?.close()
                menuOpen = false
                hideMenuMark(animated: false)
            }
            messageID = id
            bubbleLayout = layout
            removeBodyText()
            bubble.configure(layout, messageID: id)
            pills.configure(layout)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tail.isHidden = !layout.tail
            tail.path = layout.tail ? BubbleTail.path(size: layout.bubbleSize, fromMe: layout.fromMe) : nil
            CATransaction.commit()
            paintTail()
            if let person = layout.avatar {
                avatar.configure(
                    personID: person.personID, name: person.name,
                    frame: layout.avatarFrame(rowWidth: bounds.width) ?? .zero
                )
            }
            placeSubviews()
            setAccessibilityLabel(layout.accessibilityLabel)
            watchMessage()
        }
        setHighlighted(highlighted, animated: false)
    }

    /// The row scrolled out of the table, or the cell left its row (a
    /// reload gave the row another kind of cell): what plays stops, the
    /// reaction picker closes, and the next `configure` starts afresh.
    func leftScreen() {
        watches.stopAll()
        stopArrival()
        bubble.pictureView?.setMoving(false)
        if let messageID, bubbleLayout?.hasAttachment == true { delegate?.attachmentHidden(inMessage: messageID) }
        hideHoverActions(animated: false)
        // The picker closes now, reported for the message it opened for:
        // the cell may show another before the popover would report it.
        if let popover {
            popover.delegate = nil
            popover.close()
            self.popover = nil
            if let id = popoverMessage { delegate?.reactionPickerClosed(forMessage: id) }
            popoverMessage = nil
        }
        messageID = nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil, messageID != nil { leftScreen() }
    }

    /// Only what can change for this message is watched: picking, a
    /// download while the file is not here, a video or voice message that
    /// may play.
    private func watchMessage() {
        watches.stopAll()
        downloadValue = nil
        guard let id = messageID, let layout = bubbleLayout else { return }
        var initial = true
        watches.watch({ [weak self] in self?.delegate?.selectionState(forMessage: id) ?? SelectionState() }) { [weak self] state in
            // A cell set up takes the state as it is; a change after moves.
            self?.applySelection(state, animated: !initial && self?.window != nil)
            initial = false
        }
        if layout.avatar != nil {
            watches.watch({ [weak self] in self?.delegate?.senderAvatar(forMessage: id) ?? AvatarSource(url: nil, version: 0) }) { [weak self] source in
                self?.avatar.show(url: source.url, version: source.version)
            }
        }
        guard layout.hasAttachment else { return }
        delegate?.attachmentShown(inMessage: id)
        if let document = layout.document {
            if document.document.path == nil {
                watches.watch({ [weak self] in self?.delegate?.downloadState(forMessage: id) }) { [weak self] state in
                    self?.bubble.documentView?.setDownload(state)
                    self?.downloadValue = Self.accessibilityValue(state)
                }
            } else {
                bubble.documentView?.setDownload(nil)
            }
        }
        if let voice = layout.voice {
            watches.watch({ [weak self] in self?.delegate?.voiceState(forMessage: id) ?? VoiceState() }) { [weak self] state in
                self?.bubble.voiceView?.apply(state)
            }
            if voice.side != nil {
                watches.watch({ [weak self] in self?.delegate?.recorderAvatar(forMessage: id) ?? AvatarSource(url: nil, version: 0) }) { [weak self] source in
                    self?.bubble.voiceView?.showAvatar(url: source.url, version: source.version)
                }
            }
            return
        }
        guard let picture = layout.picture else { return }
        if picture.picture.path == nil, !picture.picture.isSticker {
            watches.watch({ [weak self] in self?.delegate?.downloadState(forMessage: id) }) { [weak self] state in
                self?.bubble.pictureView?.setDownload(state)
                self?.downloadValue = Self.accessibilityValue(state)
            }
        } else {
            bubble.pictureView?.setDownload(nil)
        }
        if picture.picture.kind == .video || picture.picture.kind == .roundVideo {
            watches.watch({ [weak self] in self?.delegate?.isPlayingInPlace(id) ?? false }) { [weak self] playing in
                self?.bubble.pictureView?.setPlaying(playing, player: self?.delegate?.inlinePlayer)
            }
        }
    }

    private static func accessibilityValue(_ state: DownloadState?) -> String {
        switch state {
        case .downloading: String(localized: "Downloading")
        case .failed: String(localized: "Download failed")
        case nil: String(localized: "Not downloaded")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        checkbox.appearance = effectiveAppearance
        checkbox.setNeedsDisplay()
        paintBackground(animated: false)
        paintTail()
    }

    private func paintTail() {
        guard let layout = bubbleLayout, layout.tail else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tail.fillColor = layout.bubbleColor?.cgColor
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        checkbox.contentsScale = window?.backingScaleFactor ?? 2
        checkbox.setNeedsDisplay()
        avatar.setScale(window?.backingScaleFactor ?? 2)
    }

    /// The system accent colour changed.
    func refreshColors() {
        checkbox.setNeedsDisplay()
        paintTail()
        bubble.refreshColors()
        bubble.pictureView?.refreshColors()
        bubble.documentView?.refreshColors()
        bubble.voiceView?.refreshColors()
        bubble.linkView?.refreshColors()
        pills.needsRedraw()
    }

    func setHighlighted(_ on: Bool, animated: Bool) {
        guard on != highlighted else { return }
        highlighted = on
        paintBackground(animated: animated)
    }

    /// The message's menu opened or closed: the bubble itself (its tail
    /// too, not the row) darkens meanwhile, as WhatsApp and Telegram mark
    /// the message a menu is for; quickly on, gently off.
    func setMenuOpen(_ open: Bool) {
        guard open != menuOpen else { return }
        menuOpen = open
        let animated = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if open {
            showMenuMark(animated: animated)
        } else {
            hideMenuMark(animated: animated)
        }
    }

    /// Whether the bubble shows that its menu is open.
    var showsMenuMark: Bool { menuMark != nil }

    private func showMenuMark(animated: Bool) {
        guard let layout = bubbleLayout else { return }
        hideMenuMark(animated: false)
        let shift = selection.selecting && !layout.fromMe ? Self.checkboxRoom : 0
        let frame = layout.bubbleFrame(rowWidth: bounds.width).offsetBy(dx: shift, dy: 0)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink = (dark ? NSColor.white : NSColor.black).cgColor
        // The pieces are opaque and the group is faded as one, so where the
        // tail meets the rounded corner it is no darker than elsewhere.
        let view = PassiveLayerView(frame: frame)
        guard let mark = view.layer else { return }
        mark.allowsGroupOpacity = true
        mark.opacity = Float(dark ? 0.14 : 0.1)
        let radius = layout.bare ? Metrics.controlRadius : Metrics.bubbleRadius
        let body = CAShapeLayer()
        body.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        body.fillColor = ink
        mark.addSublayer(body)
        if layout.tail, !layout.bare {
            let tail = CAShapeLayer()
            tail.path = BubbleTail.path(size: frame.size, fromMe: layout.fromMe)
            tail.fillColor = ink
            mark.addSublayer(tail)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addSubview(view, positioned: .above, relativeTo: bubble)
        CATransaction.commit()
        menuMark = view
        guard animated else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = mark.opacity
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mark.add(fade, forKey: "fade")
    }

    private func hideMenuMark(animated: Bool) {
        guard let view = menuMark else { return }
        menuMark = nil
        guard animated, let mark = view.layer else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { view.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = mark.presentation()?.opacity ?? mark.opacity
        fade.toValue = 0
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mark.opacity = 0
        mark.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// A search hit or quote jumped to is marked, else a picked message.
    private func paintBackground(animated: Bool, duration: CFTimeInterval = 0.6) {
        let accent = bubbleLayout?.accent ?? .controlAccentColor
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if highlighted {
                color = accent.withAlphaComponent(0.18).cgColor
            } else if selection.selecting, selection.selected {
                color = accent.withAlphaComponent(0.12).cgColor
            }
        }
        CATransaction.begin()
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer?.backgroundColor = color
        CATransaction.commit()
    }

    /// Frames are set here, not in `layout()`: marking a cell as needing
    /// layout sends the window's layout pass through the SwiftUI hosting
    /// view at its root on every reuse, which cost more than the cells.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { placeSubviews() }
    }

    private func placeSubviews(animated: Bool = false) {
        guard let layout = bubbleLayout else { return }
        let shift = selection.selecting && !layout.fromMe ? Self.checkboxRoom : 0
        let bubbleFrame = layout.bubbleFrame(rowWidth: bounds.width).offsetBy(dx: shift, dy: 0)
        let pillsFrame = layout.pillsFrame(rowWidth: bounds.width).insetBy(dx: -2, dy: -2).offsetBy(dx: shift, dy: 0)
        pills.isHidden = layout.pills.isEmpty
        if animated {
            // The tail moves with the bubble.
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = tail.position
            move.duration = 0.2
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tail.add(move, forKey: "position")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bubble.animator().frame = bubbleFrame
                if !layout.pills.isEmpty { pills.animator().frame = pillsFrame }
            }
        } else {
            bubble.frame = bubbleFrame
            if !layout.pills.isEmpty { pills.frame = pillsFrame }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        checkbox.frame = CGRect(x: Metrics.m, y: ((bounds.height - 24) / 2).rounded(), width: 24, height: 24)
        tail.frame = bubbleFrame
        let avatarFrame = layout.avatarFrame(rowWidth: bounds.width)
        avatar.layer.isHidden = avatarFrame == nil
        if let avatarFrame { avatar.layer.frame = avatarFrame.offsetBy(dx: shift, dy: 0) }
        CATransaction.commit()
        placeHoverActions()
    }

    /// Where the sender's photo is, when the row shows one.
    private func avatarFrame() -> CGRect? {
        avatar.layer.isHidden ? nil : avatar.layer.frame
    }

    // MARK: Picking

    private func applySelection(_ state: SelectionState, animated: Bool) {
        let moved = state.selecting != selection.selecting
        selection = state
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if state.selecting {
            hideHoverActions(animated: false)
            removeBodyText()
            checkbox.appearance = effectiveAppearance
            checkbox.configure(
                symbol: state.selected ? "checkmark.circle.fill" : "circle", pointSize: 20, weight: .regular,
                palette: [state.selected ? bubbleLayout?.accent ?? .controlAccentColor : .secondaryLabelColor]
            )
            checkbox.opacity = state.enabled ? 1 : 0.3
        }
        if moved {
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.2)
            } else {
                CATransaction.setDisableActions(true)
            }
            checkbox.isHidden = !state.selecting
            CATransaction.commit()
            placeSubviews(animated: animated)
        }
        paintBackground(animated: false)
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        if selection.selecting, selection.enabled {
            setAccessibilityValue(selection.selected ? String(localized: "Selected") : String(localized: "Not selected"))
        } else {
            setAccessibilityValue(downloadValue)
        }
    }

    /// While picking, the whole row is one target: a click picks it, and
    /// nothing inside (links, text, a photo) takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard selection.selecting else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    /// The message's menu, from anywhere on its row: the bubble and the
    /// space beside it (upstream #240).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = messageID else { return super.menu(for: event) }
        return delegate?.menu(forMessage: id, selection: nil)
    }

    // MARK: Pointer

    /// The pointer is over this row, at `point` (the table tracks it: cells
    /// have no tracking areas or cursor rects of their own, which AppKit
    /// recomputed for every cell on every frame of a scroll).
    func pointerMoved(to point: NSPoint) {
        // While picking a click picks the row: no text to select, no
        // controls beside it, the plain arrow.
        guard !selection.selecting else {
            NSCursor.arrow.set()
            return
        }
        if !hovering {
            hovering = true
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.restDelay))
                guard let self, !Task.isCancelled, self.hovering else { return }
                self.showHoverActions()
            }
        }
        let inBubble = bubble.convert(point, from: self)
        bubble.pointerMoved(to: inBubble)
        // The photo opens the sender's page, as their name does.
        if avatarFrame()?.contains(point) == true { NSCursor.pointingHand.set() }
    }

    /// The pointer left the row, or the row went off screen under it.
    func pointerLeft() {
        guard hovering else { return }
        hovering = false
        hoverTask?.cancel()
        bubble.pointerLeft()
        guard let id = messageID, delegate?.isPickingReaction(forMessage: id) != true else { return }
        hideHoverActions(animated: true)
    }

    /// How long the pointer rests before a row makes its hover views.
    static let restDelay = 150

    private func showHoverActions() {
        guard !selection.selecting, hoverActions == nil, let id = messageID,
              let view = delegate?.hoverActions(forMessage: id) else { return }
        hoverActions = view
        view.alphaValue = 0
        addSubview(view)
        placeHoverActions()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            view.animator().alphaValue = 1
        }
    }

    private func hideHoverActions(animated: Bool) {
        guard let view = hoverActions else { return }
        hoverActions = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            view.animator().alphaValue = 0
        } completionHandler: {
            // AppKit calls this on the main thread.
            MainActor.assumeIsolated { view.removeFromSuperview() }
        }
    }

    /// Beside the bubble, clear of it, on the side away from the window's
    /// edge, centred on it, as `MessageRow` places them.
    private func placeHoverActions() {
        guard let view = hoverActions, let layout = bubbleLayout else { return }
        let bubble = layout.bubbleFrame(rowWidth: bounds.width)
        let size = view.frame.size
        let gap = HoverActions.gap
        let x = layout.fromMe ? bubble.minX - gap - size.width : bubble.maxX + gap
        view.setFrameOrigin(NSPoint(x: x.rounded(), y: (bubble.midY - size.height / 2).rounded()))
    }

    /// The reaction picker, from the hover control or the message's menu.
    func showReactionPicker() {
        guard popover == nil, let id = messageID, let controller = delegate?.reactionPicker(forMessage: id) else { return }
        showHoverActions()
        let popover = NSPopover()
        popover.contentViewController = controller
        let fitting = controller.view.fittingSize
        if fitting.width > 0, fitting.height > 0 { popover.contentSize = fitting }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        self.popover = popover
        popoverMessage = id
        popover.show(relativeTo: bubble.bounds, of: bubble, preferredEdge: .minY)
    }

    func closeReactionPicker() {
        popover?.close()
    }

    #if DEBUG
    /// As a click on the sender's photo, or the name when there is no photo.
    func debugClickSender() {
        guard let id = messageID else { return }
        if let avatar = avatarFrame() {
            delegate?.showSender(ofMessage: id, relativeTo: avatar, of: self, preferredEdge: .maxX)
        } else if let name = bubbleLayout?.name {
            delegate?.showSender(ofMessage: id, relativeTo: name.rect, of: bubble, preferredEdge: .minY)
        }
    }
    #endif

    override func mouseDown(with event: NSEvent) {
        if selection.selecting, let id = messageID {
            let range = event.modifierFlags.contains(.shift)
            delegate?.toggleSelection(ofMessage: id, range: range)
            // A drag from a row picks each one it passes, as a click on each would.
            if !range { _ = delegate?.sweep(fromMessage: id, event: event) }
            return
        }
        if event.modifierFlags.contains(.command), let id = messageID {
            delegate?.startSelecting(fromMessage: id)
            return
        }
        if let id = messageID, let avatar = avatarFrame(), avatar.contains(convert(event.locationInWindow, from: nil)) {
            delegate?.showSender(ofMessage: id, relativeTo: avatar, of: self, preferredEdge: .maxX)
            return
        }
        // A drag down the space beside the bubble starts picking messages
        // (over the text it selects text instead); a click there is the
        // table's, and puts the cursor back in the composer.
        if let id = messageID, isBesideBubble(event) {
            if delegate?.sweep(fromMessage: id, event: event) == true { return }
            super.mouseDown(with: event)
            delegate?.clickedBesideMessages()
            return
        }
        super.mouseDown(with: event)
    }

    /// Whether the press is on the row but not on its bubble.
    private func isBesideBubble(_ event: NSEvent) -> Bool {
        guard let layout = bubbleLayout else { return false }
        return !layout.bubbleFrame(rowWidth: bounds.width).contains(convert(event.locationInWindow, from: nil))
    }

    // MARK: Selectable text

    var bodyText: BodyTextView? { bubble.bodyText }

    func installBodyText() -> BodyTextView? {
        guard let layout = bubbleLayout, let body = layout.body, bubble.bodyText == nil else { return bubble.bodyText }
        let view = BodyTextView(layout: layout, body: body)
        view.cell = self
        bubble.showBodyText(view)
        return view
    }

    func removeBodyText() {
        bubble.hideBodyText()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let id = messageID else { return nil }
        return delegate?.accessibilityActions(forMessage: id)
    }
}

extension BubbleCell: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if let id = popoverMessage { delegate?.reactionPickerClosed(forMessage: id) }
        popoverMessage = nil
        if !hovering { hideHoverActions(animated: true) }
    }
}

/// A layer-backed view that only shows its layer: no drawing, no clicks.
final class PassiveLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Bubble

/// The bubble: its shape as a layer background, text in two layers (the
/// body alone, so a text view can stand in for it).
private final class BubbleView: NSView {
    weak var cell: BubbleCell?
    private(set) var bodyText: BodyTextView?
    private(set) var pictureView: PictureView?
    private(set) var documentView: DocumentView?
    private(set) var voiceView: VoiceView?
    private(set) var linkView: LinkPreviewView?
    private let chrome = BubbleChromeLayer()
    private let body = TextLayer()
    /// The quoted message's picture, on the quote's right.
    private let quoteImage = CALayer()
    private var quoteLoads = 0
    private var bubbleLayout: BubbleLayout?
    private var bodyHover: Task<Void, Never>?
    private var overBody = false
    private var overPicture = false
    private var pictureRest: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = Metrics.bubbleRadius
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(chrome)
        layer?.addSublayer(body)
        quoteImage.contentsGravity = .resizeAspectFill
        quoteImage.masksToBounds = true
        quoteImage.cornerRadius = Metrics.controlRadius
        quoteImage.cornerCurve = .continuous
        // Flush with the quote's right edge, whose corners it rounds.
        quoteImage.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        quoteImage.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(quoteImage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout, messageID: String) {
        bubbleLayout = layout
        if let picture = layout.picture {
            let view = install(&pictureView, frame: picture.frame) { PictureView() }
            view.cell = cell
            view.configure(picture, messageID: messageID, color: layout.textColor)
        } else {
            remove(&pictureView)
        }
        if let document = layout.document {
            let view = install(&documentView, frame: document.frame) { DocumentView() }
            view.cell = cell
            view.configure(document, messageID: messageID, color: layout.textColor)
        } else {
            remove(&documentView)
        }
        if let voice = layout.voice {
            let view = install(&voiceView, frame: voice.frame) { VoiceView() }
            view.cell = cell
            view.configure(voice, messageID: messageID, bubbleColor: layout.bubbleColor)
        } else {
            remove(&voiceView)
        }
        if let preview = layout.linkPreview {
            let view = install(&linkView, frame: preview.frame) { LinkPreviewView() }
            view.cell = cell
            view.configure(preview, messageID: messageID)
        } else {
            remove(&linkView)
        }
        overPicture = false
        showQuotePicture(layout.quote, messageID: messageID)
        chrome.layout = layout
        body.piece = layout.body.map { TextPiece(string: $0.string, rect: CGRect(origin: .zero, size: $0.rect.size)) }
        body.isHidden = layout.body == nil
        applyAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chrome.frame = CGRect(origin: .zero, size: layout.bubbleSize)
        body.frame = layout.body?.rect ?? .zero
        CATransaction.commit()
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
        overBody = false
        bodyHover?.cancel()
    }

    func refreshColors() {
        applyAppearance()
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
    }

    private func showQuotePicture(_ quote: BubbleLayout.QuoteLayout?, messageID: String) {
        quoteLoads += 1
        let load = quoteLoads
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quoteImage.frame = quote?.thumbnail ?? .zero
        quoteImage.isHidden = quote?.thumbnail == nil
        CATransaction.commit()
        guard let rect = quote?.thumbnail, let data = quote?.thumbnailData else {
            quoteImage.contents = nil
            return
        }
        let key = "quote-\(messageID)"
        let points = max(rect.width, rect.height)
        if let cached = Thumbnails.cached(key: key, points: points) {
            quoteImage.contents = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return
        }
        quoteImage.contents = nil
        Task { [weak self] in
            let image = await Thumbnails.load(data, key: key, points: points)
            guard let self, self.quoteLoads == load else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.quoteImage.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            CATransaction.commit()
        }
    }

    /// The attachment's view, made the first time a message needs it.
    private func install<View: NSView>(_ view: inout View?, frame: CGRect, make: () -> View) -> View {
        let made = view ?? make()
        if made.superview == nil { addSubview(made) }
        made.frame = frame
        view = made
        return made
    }

    private func remove<View: NSView>(_ view: inout View?) {
        view?.removeFromSuperview()
        view = nil
    }

    private func applyAppearance() {
        guard let layout = bubbleLayout else { return }
        chrome.appearance = effectiveAppearance
        body.appearance = effectiveAppearance
        // Without a bubble there is no shape to round, and the rounding
        // would clip the sender's name at the corner.
        layer?.cornerRadius = layout.bare ? 0 : Metrics.bubbleRadius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = layout.bubbleColor?.cgColor
        }
        let lifted = layout.lifted && layout.bubbleColor != nil
        layer?.shadowOpacity = lifted ? 0.1 : 0
        if lifted {
            // A known shape, so the shadow needs no offscreen pass.
            layer?.shadowPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: layout.bubbleSize),
                cornerWidth: Metrics.bubbleRadius, cornerHeight: Metrics.bubbleRadius, transform: nil
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        chrome.contentsScale = scale
        body.contentsScale = scale
        chrome.setNeedsDisplay()
        body.setNeedsDisplay()
    }

    func showBodyText(_ view: BodyTextView) {
        bodyText = view
        addSubview(view)
        body.isHidden = true
    }

    func hideBodyText() {
        guard let view = bodyText else { return }
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(view.enclosingScrollView?.documentView) }
        view.removeFromSuperview()
        bodyText = nil
        body.isHidden = false
    }

    // MARK: Pointer

    /// The text view is made once the pointer rests on the text: made for
    /// every bubble the pointer crossed while scrolling, text views were
    /// most of the frame in Telefast's traces. The quote and the sender's
    /// name show the pointing hand.
    func pointerMoved(to point: NSPoint) {
        guard let layout = bubbleLayout else { return }
        let clickable = layout.quote?.rect.contains(point) == true || layout.name?.rect.contains(point) == true
            || layout.linkPreview?.frame.contains(point) == true
        if bodyText == nil { (clickable ? NSCursor.pointingHand : NSCursor.arrow).set() }
        let picture = layout.picture?.frame.contains(point) == true
        if picture != overPicture {
            overPicture = picture
            pictureRest?.cancel()
            if picture {
                // A GIF moves once the pointer rests on it, not as it passes.
                pictureRest = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(BubbleCell.restDelay))
                    guard let self, !Task.isCancelled else { return }
                    self.pointerRested()
                }
            } else {
                pictureView?.setMoving(false)
            }
        }
        let body = layout.body?.rect.contains(point) == true
        guard body != overBody else { return }
        overBody = body
        bodyHover?.cancel()
        if body {
            bodyHover = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(BubbleCell.restDelay))
                guard let self, !Task.isCancelled, let cell = self.cell else { return }
                cell.delegate?.bodyHovered(in: cell)
            }
        } else if let view = bodyText, view.selectedRange().length == 0 {
            hideBodyText()
        }
    }

    /// The pointer rested on the row: a GIF or animated sticker under it
    /// moves.
    func pointerRested() {
        guard overPicture, let window, window.isKeyWindow else { return }
        pictureView?.setMoving(true)
    }

    func pointerLeft() {
        overBody = false
        overPicture = false
        pictureRest?.cancel()
        pictureView?.setMoving(false)
        bodyHover?.cancel()
        NSCursor.arrow.set()
        if let view = bodyText, view.selectedRange().length == 0 { hideBodyText() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-click selects messages; the cell handles it.
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let quote = bubbleLayout?.quote, quote.rect.contains(point), let cell, let id = cell.messageID {
            cell.delegate?.showQuote(ofMessage: id)
            return
        }
        if let name = bubbleLayout?.name, name.rect.contains(point), let cell, let id = cell.messageID {
            cell.delegate?.showSender(ofMessage: id, relativeTo: name.rect, of: self, preferredEdge: .minY)
            return
        }
        if let bodyRect = bubbleLayout?.body?.rect, bodyRect.contains(point), let cell, let view = cell.installBodyText() {
            view.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell, let id = cell.messageID else { return nil }
        return cell.delegate?.menu(forMessage: id, selection: nil)
    }

}

/// Everything in a bubble except the body: sender, forwarded, the quote and
/// the footer.
nonisolated private final class BubbleChromeLayer: CALayer {
    // Set on the main thread; read in draw(in:), which Core Animation also
    // calls on the main thread, during the commit.
    nonisolated(unsafe) var layout: BubbleLayout?
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
        guard let layout else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) { Self.draw(layout) }
        }
    }


    @MainActor
    private static let capsuleFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.17, alpha: 0.9)
            : NSColor(white: 0.93, alpha: 0.9)
    }

    @MainActor
    private static func draw(_ layout: BubbleLayout) {
        layout.name?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        layout.phone?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let placeholder = layout.placeholder {
            Symbols.draw(placeholder.symbol, in: placeholder.icon, pointSize: TimelineText.body.pointSize, weight: .regular, color: placeholder.color)
            placeholder.text.draw()
        }
        if let forwarded = layout.forwarded, let icon = layout.forwardedIcon {
            Symbols.draw("arrowshape.turn.up.right", in: icon, pointSize: TimelineText.caption.pointSize, weight: .regular, color: layout.footer.secondary)
            forwarded.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let quote = layout.quote {
            let shape = NSBezierPath(roundedRect: quote.rect, xRadius: Metrics.controlRadius, yRadius: Metrics.controlRadius)
            AppKitPalette.inset.setFill()
            shape.fill()
            // The bar is the quote's left edge, rounded with its corners.
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            quote.barColor.setFill()
            quote.bar.fill()
            NSGraphicsContext.restoreGraphicsState()
            quote.name.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            quote.phone?.draw(options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if let symbol = quote.symbol, let rect = quote.symbolRect {
                Symbols.draw(symbol, in: rect, pointSize: quote.symbolSize, weight: .regular, color: quote.symbolColor)
            }
            quote.summary.draw(options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        let footer = layout.footer
        if let capsule = footer.capsule {
            // The material SwiftUI puts behind it, as a nearly opaque fill
            // that reads over a wallpaper or a photo.
            capsuleFill.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        }
        footer.edited?.draw()
        footer.time.draw()
        if let ticks = footer.ticks {
            Symbols.drawTicks(DeliveryTicks.State(footer.state), in: ticks, secondary: footer.secondary, read: footer.tint)
        }
    }
}

/// One piece of text in its own 8-bit layer.
nonisolated final class TextLayer: CALayer {
    nonisolated(unsafe) var piece: TextPiece?
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
        guard let piece else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) { piece.draw() }
        }
    }
}

/// An SF Symbol centred in its own 8-bit layer: one colour, or a palette
/// of several for symbols drawn in layers (a play button's circle).
nonisolated final class SymbolLayer: CALayer {
    nonisolated(unsafe) private var symbol: String?
    nonisolated(unsafe) private var pointSize: CGFloat = 13
    nonisolated(unsafe) private var weight: NSFont.Weight = .regular
    nonisolated(unsafe) private var palette: [NSColor] = []
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// Whether this changed what the layer draws.
    @MainActor
    @discardableResult
    func configure(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, palette: [NSColor]) -> Bool {
        guard symbol != self.symbol || pointSize != self.pointSize || weight != self.weight || palette != self.palette else { return false }
        self.symbol = symbol
        self.pointSize = pointSize
        self.weight = weight
        self.palette = palette
        setNeedsDisplay()
        return true
    }

    override func draw(in context: CGContext) {
        guard let symbol else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        let bounds = bounds
        let (pointSize, weight, palette) = (pointSize, weight, palette)
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                Symbols.drawCentered(symbol, in: bounds, pointSize: pointSize, weight: weight, palette: palette)
            }
        }
    }
}

// MARK: - Reactions

/// The reaction pills under a bubble: who chose each shows on hover, and a
/// click adds our reaction or takes it away, as upstream's pills do.
private final class ReactionPillsView: NSView, NSViewToolTipOwner {
    private let drawing = PillsLayer()
    weak var cell: BubbleCell?
    private var pills: [BubbleLayout.Pill] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(drawing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout) {
        drawing.layout = layout
        pills = layout.pills
        removeAllToolTips()
        for (index, pill) in pills.enumerated() {
            addToolTip(Self.frame(of: pill), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        needsRedraw()
    }

    /// The pill's place in this view, two points in for the shadow.
    private static func frame(of pill: BubbleLayout.Pill) -> CGRect {
        pill.rect.offsetBy(dx: 2, dy: 2)
    }

    private func pill(at point: NSPoint) -> BubbleLayout.Pill? {
        pills.first { Self.frame(of: $0).contains(point) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let index = Int(bitPattern: data) - 1
        guard pills.indices.contains(index), let cell, let id = cell.messageID else { return "" }
        return cell.delegate?.reactionNames(pills[index].value, ofMessage: id) ?? ""
    }

    override func mouseDown(with event: NSEvent) {
        guard let pill = pill(at: convert(event.locationInWindow, from: nil)), let cell, let id = cell.messageID else {
            return super.mouseDown(with: event)
        }
        cell.delegate?.toggleReaction(pill.value, ofMessage: id)
    }

    override func resetCursorRects() {
        for pill in pills { addCursorRect(Self.frame(of: pill), cursor: .pointingHand) }
    }

    func needsRedraw() {
        drawing.appearance = effectiveAppearance
        drawing.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawing.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawing.contentsScale = window?.backingScaleFactor ?? 2
        drawing.setNeedsDisplay()
    }

    /// Only the pills take clicks; between them the bubble's row does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return pill(at: convert(point, from: superview)) == nil ? nil : self
    }
}

nonisolated private final class PillsLayer: CALayer {
    nonisolated(unsafe) var layout: BubbleLayout?
    nonisolated(unsafe) var appearance: NSAppearance?

    override init() {
        super.init()
        contentsFormat = .RGBA8Uint
        contentsScale = 2
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    override func draw(in context: CGContext) {
        guard let layout, !layout.pills.isEmpty else { return }
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let appearance = appearance
        MainActor.assumeIsolated {
            withAppKitContext(context, appearance: appearance) {
                // The view is two points larger on each side, for the shadow.
                let transform = NSAffineTransform()
                transform.translateX(by: 2, yBy: 2)
                transform.concat()
                for pill in layout.pills {
                    let path = NSBezierPath(roundedRect: pill.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: pill.rect.height / 2, yRadius: pill.rect.height / 2)
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
                    shadow.shadowBlurRadius = 1
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.set()
                    NSColor.textBackgroundColor.setFill()
                    path.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    NSColor.separatorColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    pill.emoji.draw()
                    pill.count?.draw()
                }
            }
        }
    }
}

// MARK: - Selectable body

/// The body as a real text view, for selecting, copying and clicking links.
/// TextKit 1 with no padding lays the string out exactly as the string
/// drawing that measured it. The footer's room at the end is never selected
/// or copied.
final class BodyTextView: NSTextView, NSTextViewDelegate {
    weak var cell: BubbleCell?
    private let visibleLength: Int

    init(layout: BubbleLayout, body: TextPiece) {
        visibleLength = layout.bodyLength
        let storage = NSTextStorage(attributedString: layout.linkedBody ?? body.string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: body.rect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        super.init(frame: body.rect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: layout.linkColor, .cursor: NSCursor.pointingHand]
        if layout.fromMe {
            // The usual selection colour is the accent, which the bubble is.
            selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.35)]
        }
        delegate = self
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        visibleLength = 0
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var selectedText: String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        return (string as NSString).substring(with: range)
    }

    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        let end = min(NSMaxRange(range), visibleLength)
        let start = min(range.location, end)
        return NSRange(location: start, length: end - start)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘-click selects messages, on the text as anywhere on the row.
        if event.modifierFlags.contains(.command), let cell {
            cell.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { cell?.delegate?.bodyTextBecameActive(self) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell, let id = cell.messageID else { return nil }
        return cell.delegate?.menu(forMessage: id, selection: selectedText)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        cell?.delegate?.open(url)
        return true
    }
}

// MARK: - Drawing helpers

/// Runs AppKit drawing into a layer's context, top-left based, with the
/// view's appearance so dynamic colours resolve for light or dark.
@MainActor
func withAppKitContext(_ context: CGContext, appearance: NSAppearance?, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance(draw)
    NSGraphicsContext.restoreGraphicsState()
}

/// SF Symbols drawn as tinted images, cached per name, size and colour.
@MainActor
enum Symbols {
    private static var cache: [String: NSImage] = [:]

    static func draw(_ name: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor, offset: CGFloat = 0) {
        guard let (image, alpha) = image(name, pointSize: pointSize, weight: weight, color: color) else { return }
        let size = image.size
        let origin = CGPoint(x: rect.minX + offset, y: rect.midY - size.height / 2)
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// The symbol in the colour, opaque, and the alpha to draw it at.
    /// Monochrome, as SwiftUI draws a symbol in text: palette colours fill
    /// some symbols' inner layers (the iPhone's screen).
    static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> (NSImage, CGFloat)? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let alpha = resolved.alphaComponent
        let opaque = resolved.withAlphaComponent(1)
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(opaque.description)"
        if let cached = cache[key] { return (cached, alpha) }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let made = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            opaque.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache[key] = made
        return (made, alpha)
    }

    /// Centred in `rect`: one colour tints it (as `image` does), more
    /// colours paint its layers in order.
    static func drawCentered(_ name: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight, palette: [NSColor]) {
        let image: NSImage
        var alpha: CGFloat = 1
        if palette.count == 1 {
            guard let (tinted, fraction) = Self.image(name, pointSize: pointSize, weight: weight, color: palette[0]) else { return }
            image = tinted
            alpha = fraction
        } else {
            let colors = palette.map { $0.usingColorSpace(.sRGB) ?? $0 }
            let key = "palette|\(name)|\(pointSize)|\(weight.rawValue)|\(colors.map(\.description).joined(separator: ","))"
            if let cached = cache[key] {
                image = cached
            } else {
                let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                    .applying(.init(paletteColors: colors))
                guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) else { return }
                cache[key] = made
                image = made
            }
        }
        let size = image.size
        let origin = CGPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded())
        image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// `DeliveryTicks`, drawn: one tick sent, two delivered, two tinted read.
    static func drawTicks(_ state: DeliveryTicks.State, in rect: CGRect, secondary: NSColor, read: NSColor) {
        switch state {
        case .pending:
            draw("clock", in: rect, pointSize: 9, weight: .bold, color: secondary)
        case .sent:
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: secondary)
        case .delivered, .read:
            let color = state == .read ? read : secondary
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: color)
            draw("checkmark", in: rect, pointSize: 9, weight: .bold, color: color, offset: 4)
        case .failed:
            draw("exclamationmark.circle.fill", in: rect, pointSize: 9, weight: .bold, color: .systemRed)
        }
    }
}
