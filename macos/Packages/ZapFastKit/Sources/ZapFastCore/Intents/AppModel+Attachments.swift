/// Staging files to send, the editor that crops and marks them up, and what
/// another app shares into ZapFast.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ImageIO
import ZapFastBridge

extension AppModel {
    // MARK: Intents: attachments

    /// Stages files above the composer (picked, dropped or pasted); they go
    /// with the next send. An edit in progress gives way to them.
    public func stage(files urls: [URL], in chat: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        stage(files.map { Attachment(.file($0)) }, in: chat)
    }

    /// Stages a pasted picture.
    public func stage(image: PastedImage, in chat: String) {
        stage([Attachment(.image(image))], in: chat)
    }

    /// A photo or video opens the media editor over the chat, as on the
    /// phone; the text typed so far becomes the first one's caption.
    func stage(_ added: [Attachment], in chat: String) {
        cancelEditing(in: chat)
        var added = added
        if !isEditingMedia(in: chat), added.contains(where: \.isMedia) {
            let text = composerText[chat] ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let first = (attachments[chat] ?? []).isEmpty ? 0 : nil
                if let first {
                    added[first].caption = text
                } else {
                    attachments[chat]?[0].caption = text
                }
                composerText[chat] = ""
            }
        }
        attachments[chat, default: []] += added
        composerFocusRequests += 1
    }

    public func removeAttachment(_ id: Attachment.ID, in chat: String) {
        guard let index = attachments[chat]?.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments[chat]!.remove(at: index)
        if attachments[chat]?.isEmpty == true {
            attachments[chat] = nil
            // The last caption goes back to the field, as the text came.
            restoreCaption(removed.caption, in: chat)
        } else if index == 0, !removed.caption.isEmpty, attachments[chat]![0].caption.isEmpty {
            attachments[chat]![0].caption = removed.caption
        }
    }

    // MARK: Intents: the media editor

    /// Photos or videos are staged, so the media editor shows.
    public func isEditingMedia(in chat: String) -> Bool {
        mediaEditorChats.contains(chat)
    }

    public func setEdit(_ edit: MediaEdit, for id: Attachment.ID, in chat: String) {
        guard let index = attachments[chat]?.firstIndex(where: { $0.id == id }) else { return }
        attachments[chat]![index].edit = edit
    }

    public func setCaption(_ caption: String, for id: Attachment.ID, in chat: String) {
        guard let index = attachments[chat]?.firstIndex(where: { $0.id == id }) else { return }
        attachments[chat]![index].caption = caption
    }

    /// Escape in the composer once nothing nearer takes it (upstream's
    /// chain): staged files go first, then the chat closes. A reply or an
    /// edit is cancelled by its own strip before this.
    public func escapeInComposer(_ chat: String) -> Bool {
        if !(attachments[chat] ?? []).isEmpty {
            discardAttachments(in: chat)
            return true
        }
        guard selectedChatID == chat, replyingTo[chat] == nil, editing[chat] == nil else { return false }
        selectedChatID = nil
        return true
    }

    /// Closes the editor without sending. The first caption returns to the
    /// field, so nothing typed is lost.
    public func discardAttachments(in chat: String) {
        guard let staged = attachments.removeValue(forKey: chat) else { return }
        restoreCaption(staged.first(where: { !$0.caption.isEmpty })?.caption ?? "", in: chat)
    }

    private func restoreCaption(_ caption: String, in chat: String) {
        guard !caption.isEmpty, (composerText[chat] ?? "").isEmpty else { return }
        composerText[chat] = caption
    }

    /// Sends what the editor holds, each with its own caption and the
    /// reply on the first, in order. Photos are redrawn at the chosen
    /// quality and videos re-encoded first, off the main thread; a
    /// document among them goes as it is.
    public func sendMedia(in chat: String) {
        guard let staged = attachments.removeValue(forKey: chat), !staged.isEmpty else { return }
        let quality = preferences.mediaQuality
        let picked = composerMentions.removeValue(forKey: chat) ?? []
        let participants = chats.chat(chat)?.participants ?? []
        var quoting = replyingTo.removeValue(forKey: chat)?.id
        stopComposing(in: chat)
        preparingMedia[chat, default: 0] += staged.count
        let outgoing = MediaExport.outgoingDirectory(in: paths.caches)
        Task {
            for attachment in staged {
                defer {
                    preparingMedia[chat, default: 1] -= 1
                    if preparingMedia[chat] == 0 { preparingMedia[chat] = nil }
                }
                let path: String
                do {
                    path = try await prepare(attachment, quality: quality, outgoing: outgoing)
                } catch {
                    post(.error, error.localizedDescription)
                    continue
                }
                let caption = attachment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                let (encoded, mentions) = MentionEncoding.encode(caption, picked: picked, participants: participants)
                backend.send(.sendFiles(
                    chat: chat, paths: [path], caption: encoded.isEmpty ? nil : encoded,
                    mentions: mentions, quoting: quoting
                ))
                followSentChat()
                quoting = nil
            }
        }
    }

    /// The file upstream sends for an attachment.
    func prepare(_ attachment: Attachment, quality: MediaQuality, outgoing: URL) async throws -> String {
        let edit = attachment.edit
        // A file prepared before (a refused send come back) goes as it is.
        let prepared = attachment.fileURL.map { $0.deletingLastPathComponent().standardizedFileURL == outgoing.standardizedFileURL } ?? false
        switch attachment.media {
        case .none:
            guard let url = attachment.fileURL else { throw MediaExport.Failure.unreadable }
            return url.path(percentEncoded: false)
        case .video:
            guard let url = attachment.fileURL else { throw MediaExport.Failure.noVideo }
            if edit.isEmpty, quality == .hd || prepared { return url.path(percentEncoded: false) }
            let info = try await MediaExport.videoInfo(url)
            let overlays = renderOverlays(edit.overlays, longSide: max(info.size.width, info.size.height))
            let destination = try outgoingFile(in: outgoing, extension: "mp4")
            try await MediaExport.exportVideo(url, edit: edit, overlays: overlays, quality: quality, to: destination)
            return destination.path(percentEncoded: false)
        case .photo:
            if prepared, edit.isEmpty, let url = attachment.fileURL { return url.path(percentEncoded: false) }
            let plan: MediaExport.PhotoPlan
            switch attachment.kind {
            case .file(let url):
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MediaExport.Failure.unreadable }
                plan = try await MediaExport.planPhoto(source, edit: edit, quality: quality)
            case .image(let image):
                guard let picture = image.cgImage else { throw MediaExport.Failure.unreadable }
                plan = MediaExport.planPhoto(picture, edit: edit, quality: quality)
            }
            let overlays = renderOverlays(edit.overlays, longSide: max(plan.canvas.width, plan.canvas.height))
            let data = try await MediaExport.renderPhoto(plan, edit: edit, overlays: overlays, quality: quality)
            let destination = try outgoingFile(in: outgoing, extension: "jpg")
            try data.write(to: destination)
            return destination.path(percentEncoded: false)
        }
    }

    private func renderOverlays(_ overlays: [MediaOverlay], longSide: CGFloat) -> [RenderedOverlay] {
        guard let overlayRenderer else { return [] }
        return overlays.compactMap { overlay in
            overlayRenderer(overlay, longSide).map { RenderedOverlay(overlay: overlay, image: $0) }
        }
    }

    private func outgoingFile(in directory: URL, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).\(ext)")
    }

    /// Upstream's `send_pending`: the caption, its mentions and the reply
    /// travel with the first attachment; pasted images go one by one, the
    /// files together.
    func sendAttachments(in chat: String, caption text: String) {
        guard let staged = attachments.removeValue(forKey: chat), !staged.isEmpty else { return }
        let (encoded, encodedMentions) = encodeMentions(text, in: chat)
        var caption = encoded.isEmpty ? nil : encoded
        var mentions = encodedMentions
        var quoting = replyingTo.removeValue(forKey: chat)?.id
        composerText[chat] = ""
        chats.setDraft("", for: chat)
        backend.send(.saveDraft(chat: chat, text: ""))
        stopComposing(in: chat)
        var files: [String] = []
        for attachment in staged {
            switch attachment.kind {
            case .image(let image):
                backend.send(.sendImage(
                    chat: chat, width: image.width, height: image.height, rgba: image.rgba,
                    caption: caption, mentions: mentions, quoting: quoting
                ))
                followSentChat()
                caption = nil
                mentions = []
                quoting = nil
            case .file(let url):
                files.append(url.path(percentEncoded: false))
            }
        }
        if !files.isEmpty {
            backend.send(.sendFiles(chat: chat, paths: files, caption: caption, mentions: mentions, quoting: quoting))
            followSentChat()
        }
    }

    /// The composer changed: tell the chat we are typing, and that we
    /// stopped once the keys have been quiet for a few seconds.
    /// Completions for a `:shortcode` typed in the composer.
    public func emojiSuggestions(for query: String) -> [EmojiSuggestionInfo] {
        ZapFastBridge.emojiSuggestions(query: query, recent: preferences.recentEmoji)
    }

    // MARK: Intents: the Share menu

    /// A `zapfast-mac://share` link from the Share extension: asks which
    /// chat it goes to. Returns whether the link was one.
    @discardableResult
    public func receiveShare(_ url: URL) -> Bool {
        guard let request = ShareRequest.read(url) else { return false }
        shareRequest = request
        bringToFront()
        return true
    }

    /// Puts what was shared in `chat`'s composer, to be sent from there
    /// with a caption or a reply: files wait above the field, text joins
    /// what is typed.
    public func deliverShare(to chat: String) {
        guard let request = shareRequest else { return }
        shareRequest = nil
        selectedChatID = chat
        if !request.files.isEmpty { stage(files: request.files, in: chat) }
        if !request.text.isEmpty {
            let typed = composerText[chat] ?? ""
            composerText[chat] = typed.isEmpty ? request.text : typed + "\n" + request.text
        }
        composerFocusRequests += 1
    }
}
