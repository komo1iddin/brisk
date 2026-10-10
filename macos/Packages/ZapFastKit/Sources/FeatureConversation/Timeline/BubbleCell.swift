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
