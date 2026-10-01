import AppKit
import AVFoundation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

// MARK: - Cell actions

extension TimelineController: TimelineCellDelegate {
    func showQuote(ofMessage id: String) {
        guard let model, let message = message(id) else { return }
        model.showQuoted(in: message)
    }

    func showSender(ofMessage id: String) {
        guard let model, let message = message(id) else { return }
        model.showInfo(in: message.chat, person: message.sender)
    }

    func menu(forMessage id: String, selection: String?) -> NSMenu? {
        guard let model, let message = message(id) else { return nil }
        let menu = NSHostingMenu(rootView: MessageActions(message: message, model: model))
        if let selection {
            let copy = NSMenuItem(title: String(localized: "Copy Selection"), action: #selector(copySelection(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = selection
            copy.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
            menu.insertItem(copy, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func copySelection(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ url: URL) {
        guard model?.openInviteLink(url) != true else { return }
        NSWorkspace.shared.open(url)
    }

    /// One message's text is selectable at a time, as before: another's
    /// text view goes unless it holds a selection.
    func bodyHovered(in cell: BubbleCell) {
        forEachBubbleCell { other in
            guard other !== cell, let text = other.bodyText, text.selectedRange().length == 0 else { return }
            other.removeBodyText()
        }
        _ = cell.installBodyText()
    }

    func bodyTextBecameActive(_ view: BodyTextView) {
        forEachBubbleCell { other in
            if let text = other.bodyText, text !== view { other.removeBodyText() }
        }
    }

    /// ⌘-click starts selecting messages, as the SwiftUI rows' does.
    func startSelecting(fromMessage id: String) {
        guard let model, let message = message(id), model.canSelect(message) else { return }
        model.select(message)
    }

    /// Reply and React beside the bubble under the pointer, the SwiftUI
    /// rows' own view, made only while the pointer is there.
    func hoverActions(forMessage id: String) -> NSView? {
        // A deleted message takes no reply or reaction, as `MessageRow`.
        guard let model, let message = message(id), !message.isRevoked else { return nil }
        let view = NSHostingView(rootView: HoverActions(message: message, model: model)
            .environment(\.chatTheme, style.theme))
        view.sizingOptions = []
        // Its own measures: a hosting view outside a window reports no
        // fitting size for the glass group, and would centre it on nothing.
        view.frame.size = HoverActions.pairSize
        return view
    }

    func isPickingReaction(forMessage id: String) -> Bool {
        guard let model, let chatID else { return false }
        return model.reactionTarget == MessageKey(chat: chatID, message: id)
    }

    /// The reaction picker hangs from the bubble, as the SwiftUI rows' does.
    func reactionPicker(forMessage id: String) -> NSViewController? {
        guard let model, let message = message(id) else { return nil }
        return NSHostingController(rootView: ReactionPicker(
            quick: model.quickReactions(for: message),
            mine: message.reactions.first(where: \.fromMe)?.emoji,
            frequent: model.preferences.reactionEmoji.map(\.emoji)
        ) { model.react($0, to: message) })
    }

    func reactionPickerClosed(forMessage id: String) {
        guard let model, let chatID, model.reactionTarget == MessageKey(chat: chatID, message: id) else { return }
        model.reactionTarget = nil
    }

    // MARK: Attachments

    func downloadState(forMessage id: String) -> DownloadState? {
        guard let model, let chatID else { return nil }
        return model.conversations.download(MessageKey(chat: chatID, message: id))
    }

    func isPlayingInPlace(_ id: String) -> Bool {
        guard let model, let chatID else { return false }
        return model.video.isCurrent(MessageKey(chat: chatID, message: id))
    }

    var inlinePlayer: AVPlayer? {
        model?.video.player
    }

    /// As `VisualMedia` does: a round video message plays in place, photos,
    /// videos and GIFs open in the media viewer (which downloads what is not
    /// here), and a sticker opens in Quick Look.
    func activateAttachment(ofMessage id: String) {
        guard let model, let message = message(id) else { return }
        if case .video(_, _, _, _, true) = message.content {
            model.playVideo(message)
        } else if MediaGallery.kind(of: message) != nil {
            model.openMediaViewer(message)
        } else if let url = message.mediaURL {
            QuickLook.shared.show([url])
        } else {
            model.download(message)
        }
    }

    func attachmentShown(inMessage id: String) {
        guard let model, let message = message(id) else { return }
        model.autoDownload(message)
    }

    /// A video playing in place pauses once it is out of view, found by
    /// its key: a deleted message is no longer among the rows.
    func attachmentHidden(inMessage id: String) {
        guard let model, let chatID else { return }
        model.video.pause(MessageKey(chat: chatID, message: id))
    }

    func attachmentFile(ofMessage id: String) -> (url: URL, name: String)? {
        guard let message = message(id), let url = message.mediaURL else { return nil }
        return (url, AttachmentFiles.dragName(of: message, url: url))
    }

    // MARK: Voice messages

    /// Read under observation: a message that is not playing reads only
    /// whether it is, so a playing one's ticks wake no other.
    func voiceState(forMessage id: String) -> VoiceState {
        guard let model, let chatID else { return VoiceState() }
        let key = MessageKey(chat: chatID, message: id)
        let voice = model.voice
        var state = VoiceState()
        state.current = voice.isCurrent(key)
        state.busy = voice.preparing == key || model.conversations.download(key) == .downloading
        if state.current {
            state.playing = voice.isPlaying
            state.progress = voice.progress(of: key)
            state.position = voice.position
            state.duration = voice.duration
            state.speed = model.preferences.voiceSpeed
        }
        return state
    }

    func senderAvatar(forMessage id: String) -> AvatarSource {
        guard let model, let message = message(id) else { return AvatarSource(url: nil, version: 0) }
        return AvatarSource(url: model.avatars.url(for: message.sender), version: model.avatars.version(for: message.sender))
    }

    func recorderAvatar(forMessage id: String) -> AvatarSource {
        guard let model, let message = message(id) else { return AvatarSource(url: nil, version: 0) }
        let recorder = message.fromMe ? model.session.account?.id ?? message.sender : message.sender
        return AvatarSource(url: model.avatars.url(for: recorder), version: model.avatars.version(for: recorder))
    }

    func playVoice(inMessage id: String) {
        guard let model, let message = message(id) else { return }
        model.playAudio(message)
    }

    func seekVoice(inMessage id: String, to fraction: Double) {
        guard let model, let message = message(id) else { return }
        model.seekAudio(message, to: fraction)
    }

    func cycleVoiceSpeed() {
        model?.cycleVoiceSpeed()
    }

    // MARK: Picking messages

    func selectionState(forMessage id: String) -> SelectionState {
        guard let model, let chatID, let selection = model.selection, selection.chat == chatID else { return SelectionState() }
        guard let message = message(id) else { return SelectionState(selecting: true) }
        return SelectionState(selecting: true, selected: selection.ids.contains(id), enabled: model.canSelect(message))
    }

    func toggleSelection(ofMessage id: String, range: Bool) {
        guard let model, let message = message(id) else { return }
        if range { model.selectRange(to: message) } else { model.toggleSelected(message) }
    }

    /// What the pointer finds beside the bubble, as actions for VoiceOver.
    func accessibilityActions(forMessage id: String) -> [NSAccessibilityCustomAction] {
        guard let model, let message = message(id) else { return [] }
        // While picking, a click picks; so does VoiceOver's one action.
        if model.selection?.chat == chatID {
            guard model.canSelect(message) else { return [] }
            let title = model.isSelected(message) ? String(localized: "Deselect") : String(localized: "Select")
            return [NSAccessibilityCustomAction(name: title) { model.toggleSelected(message); return true }]
        }
        var actions: [NSAccessibilityCustomAction] = []
        if !message.isRevoked {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Reply")) { model.reply(to: message); return true })
            actions.append(NSAccessibilityCustomAction(name: String(localized: "React")) { model.showReactionPicker(for: message); return true })
        }
        if model.canSelect(message) {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Select")) { model.select(message); return true })
        }
        if case .audio = message.content {
            let title = message.mediaURL == nil ? String(localized: "Download") : String(localized: "Play")
            actions.append(NSAccessibilityCustomAction(name: title) { model.playAudio(message); return true })
        } else if message.content.media != nil {
            let title = message.mediaURL == nil ? String(localized: "Download") : String(localized: "Open")
            actions.append(NSAccessibilityCustomAction(name: title) { [weak self] in
                self?.activateAttachment(ofMessage: id)
                return true
            })
        }
        return actions
    }
}

private extension MessageRecord {
    var isRevoked: Bool {
        if case .revoked = content { true } else { false }
    }
}
