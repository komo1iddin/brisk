/// Playing what a chat holds: voice messages, videos, and the media viewer.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: voice messages

    /// Plays or pauses a voice message or audio attachment, downloading it
    /// first if needed.
    public func playAudio(_ message: MessageRecord) {
        guard case let .audio(media, _, voiceNote, _) = message.content else { return }
        guard let url = message.mediaURL else {
            download(message)
            return
        }
        let key = MessageKey(chat: message.chat, message: message.id)
        video.stop()
        let opus = media.mime.contains("ogg") || media.mime.contains("opus")
        let speed = voiceNote ? preferences.voiceSpeed : 1
        Task { await voice.toggle(key, url: url, opus: opus, speed: speed) }
        if voiceNote, !message.fromMe, playedTold.insert(message.id).inserted {
            backend.send(.markPlayed(
                chat: message.chat,
                message: message.id,
                sender: message.sender,
                receipts: accountPreferences.sendReadReceipts
            ))
        }
    }

    public func seekAudio(_ message: MessageRecord, to fraction: Double) {
        guard voice.isCurrent(MessageKey(chat: message.chat, message: message.id)) else {
            playAudio(message)
            return
        }
        voice.seek(to: fraction)
    }

    /// Starts recording a voice message; playback stops first.
    public func startRecording() {
        voice.stop()
        video.stop()
        Task {
            if await !recorder.start(), recorder.state == .denied {
                post(.error, String(localized: "ZapFast can't use the microphone. Allow it in System Settings › Privacy & Security › Microphone."))
            }
        }
    }

    /// Sends the recording to `chat`, replying if a reply is set. Upstream
    /// drops recordings shorter than half a second.
    public func sendRecording(in chat: String) {
        let samples = recorder.finish()
        guard samples.count >= Int(voiceSampleRate()) / 2 else { return }
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendVoice(chat: chat, samples: samples, quoting: quoting))
        followSentChat()
    }

    public func cancelRecording() {
        recorder.cancel()
    }

    /// Pauses the take, letting go of the microphone, or goes on with it.
    public func toggleRecordingPause() {
        if recorder.isPaused {
            if !recorder.resume() {
                post(.error, String(localized: "ZapFast couldn't use the microphone to go on recording."))
            }
        } else {
            recorder.pause()
        }
    }

    /// Plays a paused take back, or stops it.
    public func toggleRecordingPreview() {
        recorder.togglePreview()
    }

    /// A take this long asks before it is thrown away, so a stray Escape
    /// cannot lose it.
    public static let discardAskAfter: TimeInterval = 10

    /// Sends the refused voice message again, with the reply if one is set.
    public func resendVoice(in chat: String) {
        guard let unsent = unsentVoice, unsent.chat == chat else { return }
        unsentVoice = nil
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendVoice(chat: chat, samples: unsent.samples, quoting: quoting))
        followSentChat()
    }

    public func discardUnsentVoice() {
        unsentVoice = nil
    }

    // MARK: Intents: videos

    /// Plays or pauses a video inside its message, downloading it first if
    /// needed; one plays at a time, and voice playback stops for it.
    public func playVideo(_ message: MessageRecord) {
        guard case .video = message.content else { return }
        guard let url = message.mediaURL else {
            videoWanted = MessageKey(chat: message.chat, message: message.id)
            download(message)
            return
        }
        videoWanted = nil
        voice.stop()
        video.toggle(MessageKey(chat: message.chat, message: message.id), url: url)
    }

    /// A playing video scrolled out of view: it pauses, as upstream's does.
    public func videoHidden(_ message: MessageRecord) {
        video.pause(MessageKey(chat: message.chat, message: message.id))
    }

    /// 1× → 1.5× → 2× → 1×, as on the phone.
    public func cycleVoiceSpeed() {
        let next: Float = switch preferences.voiceSpeed {
        case ..<1.25: 1.5
        case ..<1.75: 2
        default: 1
        }
        preferences.voiceSpeed = next
        voice.setSpeed(next)
    }

    /// Upstream plays the next voice message of a run by itself.
    func continueVoice(after key: MessageKey) {
        let messages = actionMessages(in: key.chat, containing: key.message)
        guard let index = messages.firstIndex(where: { $0.id == key.message }),
              messages.indices.contains(index + 1) else { return }
        let next = messages[index + 1]
        guard case .audio(_, _, true, _) = next.content, !next.fromMe, next.mediaURL != nil else { return }
        playAudio(next)
    }

    /// Upstream's largest automatic or manual download (`ATTACHMENT_DOWNLOAD_LIMIT`).
    public static let downloadLimit: UInt64 = 64 * 1024 * 1024

    /// Upstream's rule for media scrolled into view: stickers always, other
    /// media when automatic downloads are on, never past the size limit,
    /// and never again after a failure until asked.
    public func autoDownload(_ message: MessageRecord) {
        guard let media = message.content.media, media.path == nil, media.size <= Self.downloadLimit else { return }
        let isSticker = if case .sticker = message.content { true } else { false }
        guard isSticker || accountPreferences.autoDownload else { return }
        guard conversations.download(MessageKey(chat: message.chat, message: message.id)) == nil else { return }
        download(message, automatic: true)
    }

    /// Asks once a session for a document's page preview, which WhatsApp
    /// keeps apart from the small inline one (if any): it shows before the
    /// file is here, and arrives as the message updated. Asked only while
    /// connected, so a chat opened before the link is up asks again later.
    public func fetchPreview(_ message: MessageRecord) {
        guard case .document = message.content, (message.thumbnail?.count ?? 0) < Self.sharpPreviewBytes,
              case .connected = session.link,
              previewsAsked.insert(MessageKey(chat: message.chat, message: message.id)).inserted else { return }
        backend.send(.fetchPreview(chat: message.chat, message: message.id))
    }

    /// A kept preview at least this large is already the sharp one, as the
    /// worker judges it.
    static let sharpPreviewBytes = 10_000

    /// Sends a reaction; an empty one takes ours back. Each one sent counts
    /// towards the quick reactions, as upstream's `Action::React` does.
    /// A reaction's pill, clicked: ours goes if we chose it, else we choose it.
    public func toggleReaction(_ emoji: String, on message: MessageRecord) {
        let mine = message.reactions.contains { $0.fromMe && $0.emoji == emoji }
        react(mine ? "" : emoji, to: message)
    }

    /// Who chose `emoji` on `message`, "You" first if we did.
    public func reactionNames(_ emoji: String, on message: MessageRecord) -> String {
        let chose = message.reactions.filter { $0.emoji == emoji }
        return (chose.filter(\.fromMe).map { _ in String(localized: "You") }
            + chose.filter { !$0.fromMe }.map { chats.displayName($0.sender) })
            .joined(separator: ", ")
    }

    public func react(_ emoji: String, to message: MessageRecord) {
        reactionTarget = nil
        backend.send(.react(chat: message.chat, message: message.id, emoji: emoji))
        guard !emoji.isEmpty else { return }
        var uses = preferences.reactionEmoji
        let count = (uses.first { $0.emoji == emoji }?.count ?? 0) &+ 1
        uses.removeAll { $0.emoji == emoji }
        uses.insert(ReactionUse(emoji: emoji, count: count), at: 0)
        // Stable: among equals the latest stays first.
        uses = uses.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }.map(\.element)
        preferences.reactionEmoji = Array(uses.prefix(36))
        rememberEmoji(emoji)
    }

    /// Six to offer at once, most used first, and ours if it is not among them.
    public func quickReactions(for message: MessageRecord) -> [String] {
        ZapFastBridge.quickReactions(
            preferred: preferences.reactionEmoji.map(\.emoji),
            mine: message.reactions.first(where: \.fromMe)?.emoji
        )
    }

    // MARK: Intents: the media viewer


    /// Opens a photo or video in the viewer, which plays a video itself,
    /// so the one playing in its bubble stops.
    public func openMediaViewer(_ message: MessageRecord) {
        guard MediaGallery.kind(of: message) != nil else { return }
        video.stop()
        mediaViewer = MediaViewerRequest(chat: message.chat, message: message.id)
        mediaViewerMessage = message
        if let reader = mediaViewerReader, reader.store.loadedMessage(chat: message.chat, id: message.id) == nil {
            readWindow(.around(message: message.id), in: reader)
        }
    }

    public func closeMediaViewer() {
        mediaViewer = nil
    }

    public var mediaViewerConversation: Conversation {
        mediaViewerReader?.conversation ?? Conversation()
    }

    public func loadOlderMedia(in chat: String) {
        guard let reader = mediaViewerReader, reader.chat == chat else { return }
        reader.store.retentionAnchor = reader.conversation.messages.first?.id
        loadOlder(in: reader)
    }

    public func loadNewerMedia(in chat: String) {
        guard let reader = mediaViewerReader, reader.chat == chat else { return }
        reader.store.retentionAnchor = reader.conversation.messages.last?.id
        loadNewer(in: reader)
    }

    public func selectMedia(_ id: String) {
        guard let request = mediaViewer, let message = loadedMessage(chat: request.chat, id: id),
              MediaGallery.kind(of: message) != nil else { return }
        mediaViewerMessage = message
        mediaViewerReader?.store.retentionAnchor = id
    }

    /// Return from All Media to the viewed record even if grid paging has
    /// evicted it from the gallery window.
    public func focusMedia() {
        guard let reader = mediaViewerReader, let message = mediaViewerMessage,
              reader.store.loadedMessage(chat: reader.chat, id: message.id) == nil else { return }
        readWindow(.around(message: message.id), in: reader)
    }

    public func showReactionPicker(for message: MessageRecord) {
        reactionTarget = MessageKey(chat: message.chat, message: message.id)
    }

    public func deleteForEveryone(_ message: MessageRecord) {
        backend.send(.revoke(chat: message.chat, id: message.id))
    }

    public func deleteForMe(_ message: MessageRecord) {
        backend.send(.deleteLocal(chat: message.chat, id: message.id))
    }

    /// Asks before deleting `message` for us, or for everyone.
    public func confirmDelete(_ message: MessageRecord, forEveryone: Bool) {
        messageDeletion = MessageDeletion(
            key: MessageKey(chat: message.chat, message: message.id), forEveryone: forEveryone
        )
    }

    /// Deletes the message the person confirmed, if it is still here.
    public func performDeletion(_ deletion: MessageDeletion) {
        messageDeletion = nil
        guard let message = loadedMessage(chat: deletion.key.chat, id: deletion.key.message) else { return }
        if deletion.forEveryone {
            guard canRevoke(message) else { return }
            deleteForEveryone(message)
        } else {
            deleteForMe(message)
        }
    }
}
