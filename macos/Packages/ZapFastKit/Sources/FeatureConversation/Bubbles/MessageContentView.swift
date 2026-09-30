import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What a message holds, drawn by kind.
struct MessageContentView: View {
    let message: MessageRecord
    let model: AppModel
    let textColor: Color
    /// Captions under edge-to-edge media keep the usual text inset.
    var captionInset = false
    /// The bubble's time and ticks, for content that places them itself.
    var footer: AnyView?

    var body: some View {
        switch message.content {
        case let .text(text, preview):
            VStack(alignment: .leading, spacing: Metrics.s) {
                BodyText(text: text, message: message, model: model)
                if let preview { LinkPreviewCard(preview: preview, thumbnail: message.thumbnail, key: message.id, model: model) }
            }
        case let .interactive(text, card):
            InteractiveContent(message: message, text: text, card: card, model: model)
        case let .image(caption, media):
            VisualMedia(message: message, media: media, symbol: "photo", model: model)
            caption.map { BodyText(text: $0, message: message, model: model).insetForMedia(captionInset) }
        case let .video(caption, media, seconds, _, _):
            VisualMedia(message: message, media: media, symbol: "play.circle.fill", model: model, seconds: seconds)
            caption.map { BodyText(text: $0, message: message, model: model).insetForMedia(captionInset) }
        case let .sticker(media, _):
            VisualMedia(message: message, media: media, symbol: "face.smiling", model: model, sticker: true)
        case let .audio(media, seconds, voiceNote, waveform):
            AudioContent(
                message: message, media: media, seconds: seconds, voiceNote: voiceNote,
                waveform: waveform, model: model, footer: footer
            )
        case let .document(media, fileName, caption, pages):
            DocumentContent(message: message, media: media, fileName: fileName, pages: pages, model: model)
            caption.map { BodyText(text: $0, message: message, model: model) }
        case let .location(latitude, longitude, name, address):
            LocationContent(
                message: message, latitude: latitude, longitude: longitude,
                title: name ?? String(localized: "Location"), detail: address, live: false, model: model
            )
        case let .liveLocation(latitude, longitude, accuracy, speed, _, ended, updated):
            LocationContent(
                message: message, latitude: latitude, longitude: longitude,
                title: String(localized: ended ? "Live location ended" : "Live location"),
                detail: LocationContent.liveDetail(updated: updated, speed: speed, accuracy: accuracy),
                live: !ended, model: model, version: updated
            )
        case let .contact(displayName, vcard):
            ContactCard(message: message, displayName: displayName, vcard: vcard, model: model)
        case let .poll(question, options, state):
            PollContent(message: message, question: question, options: options, state: state, model: model)
        case let .stickerPack(name, publisher, count, _):
            Button { model.viewStickerPack(message) } label: {
                HStack(spacing: Metrics.s) {
                    Image(systemName: "face.smiling").font(.title2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.body.weight(.medium))
                        Text("\(publisher) · \(count) stickers").font(.caption).opacity(0.8)
                    }
                    Spacer(minLength: Metrics.s)
                    Text("View").font(.callout.weight(.semibold))
                }
                .padding(Metrics.s)
                .background(Palette.quoteBar.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 220)
            .help("View the stickers")
        case .revoked:
            Placeholder(symbol: "nosign", text: String(localized: "This message was deleted"))
        case .unsupported(let what):
            Placeholder(symbol: "exclamationmark.triangle", text: what)
        case let .phoneOnly(viewOnce, liveLocation, _):
            Placeholder(
                symbol: "iphone",
                text: viewOnce
                    ? String(localized: "View once message. Open it on your phone.")
                    : liveLocation
                        ? String(localized: "Live location. See it on your phone.")
                        : String(localized: "This message is only on your phone.")
            )
        }
    }
}

// MARK: - Text

struct BodyText: View {
    let text: String
    let message: MessageRecord
    let model: AppModel
    /// Clear text appended so the last line leaves room for an overlaid footer.
    var reserve: String?
    @Environment(\.messageTextScale) private var scale

    var body: some View {
        let styled = Text(WhatsAppMarkup.attributed(
            text,
            mentions: message.mentions,
            name: { model.chats.displayName($0) }
        ))
        let spaced = reserve.map { styled + Text($0).font(.caption2.monospacedDigit()).foregroundStyle(.clear) } ?? styled
        spaced
        .font(.system(size: (Self.isOnlyEmoji(text) ? 40 : NSFont.systemFontSize) * scale))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        // The clear room kept for the time is not read out; the footer is.
        .accessibilityLabel(styled)
    }

    /// Up to three emoji and nothing else draw large, as on the phone.
    static func isOnlyEmoji(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { $0.unicodeScalars.first?.properties.isEmojiPresentation == true
            || ($0.unicodeScalars.count > 1 && $0.unicodeScalars.contains { $0.properties.isEmoji }) }
    }
}

private struct Placeholder: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.body.italic())
            .opacity(0.75)
    }
}

// MARK: - Contact

/// A shared contact, as on the phone: the person and their number, then
/// Message and Add when the number is a WhatsApp account (upstream's
/// contact bubble). A card without a number still shows its name.
private struct ContactCard: View {
    let message: MessageRecord
    let displayName: String
    let vcard: String
    let model: AppModel

    var body: some View {
        let contact = model.sharedContact(in: message)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.s) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact?.name ?? displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if let number = contact?.number {
                        Text(number).font(.callout).opacity(0.75).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Metrics.s)

            if let contact, let account = contact.account {
                Divider().opacity(0.6)
                HStack(spacing: 0) {
                    action("Message") { model.chat(with: contact) }
                    if !model.isKnownContact(account) {
                        Divider().frame(height: 20).opacity(0.6)
                        action("Add") { model.addContact(contact) }
                            .disabled(!model.session.isConnected)
                    }
                }
            }
        }
        .frame(minWidth: 240)
        .background(Palette.quoteBar.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
        .accessibilityElement(children: .contain)
    }

    private func action(_ title: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

// MARK: - Link preview

private struct LinkPreviewCard: View {
    let preview: LinkPreviewInfo
    let thumbnail: Data?
    let key: String
    let model: AppModel

    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.s) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = preview.title {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(2)
                }
                if let description = preview.description {
                    Text(description).font(.caption).lineLimit(2).opacity(0.8)
                }
                Text(URL(string: preview.url)?.host() ?? preview.url)
                    .font(.caption2).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.s)
        .background(Palette.quoteBar.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
        .task(id: key) {
            guard let thumbnail else { return }
            image = await Thumbnails.load(thumbnail, key: "preview-\(key)", points: 56)
        }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { open() }
    }

    private func open() {
        guard let url = URL(string: preview.url), !model.openInviteLink(url) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Media

/// Photos, videos, and stickers: the preview at the picture's shape, a
/// download button until the file is here, then a click opens it. A video
/// plays inside its message; a GIF and an animated sticker move while the
/// pointer is over them in the active window, as upstream's do.
private struct VisualMedia: View {
    let message: MessageRecord
    let media: MediaInfo
    let symbol: String
    let model: AppModel
    var seconds: UInt32?
    var sticker = false

    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = displaySize
        Group {
            if playsInline {
                PlayerView(player: model.video.player, fill: isNote, minimal: isNote)
            } else {
                poster(size)
                    .contentShape(shape)
                    .onTapGesture(perform: activate)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityTitle)
                    .accessibilityValue(accessibilityState)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .onHover { hovering = $0 }
        .draggableAttachment(message)
        .task(id: "\(message.id)-\(media.path ?? "")") { await load(size) }
        .onDisappear {
            if case .video = message.content { model.videoHidden(message) }
        }
    }

    private func poster(_ size: CGSize) -> some View {
        ZStack {
            if let url = message.mediaURL, isAnimatedSticker {
                AnimatedImage(url: url, still: image, points: max(size.width, size.height), playing: moves)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                if media.path != nil || sticker {
                    Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            if isGif, moves, let url = message.mediaURL {
                LoopingVideo(url: url)
            }
            overlay
        }
    }

    @ViewBuilder private var overlay: some View {
        let state = model.conversations.download(MessageKey(chat: message.chat, message: message.id))
        if media.path == nil, !sticker {
            DownloadBadge(state: state, size: media.size)
        } else if isGif {
            if !moves {
                Text("GIF")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(.white)
            }
        } else if case .video = message.content {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white, .black.opacity(0.35))
        }
        if let seconds, seconds > 0, !isGif {
            Text(Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond)))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: isNote ? nil : .infinity, alignment: isNote ? .center : .bottomLeading)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(Metrics.s)
        }
    }

    private var key: MessageKey { MessageKey(chat: message.chat, message: message.id) }

    /// "Video, 0:42", "GIF", "Photo", "Sticker", read as one element.
    private var accessibilityTitle: Text {
        if sticker { return Text("Sticker") }
        if isGif { return Text("GIF") }
        if case .video = message.content {
            let length = seconds.map { Duration.seconds(Int($0)).formatted(.time(pattern: .minuteSecond)) }
            if let length { return isNote ? Text("Video message, \(length)") : Text("Video, \(length)") }
            return isNote ? Text("Video message") : Text("Video")
        }
        return Text("Photo")
    }

    private var accessibilityState: Text {
        guard media.path == nil, !sticker else { return Text(verbatim: "") }
        switch model.conversations.download(key) {
        case .downloading: return Text("Downloading")
        case .failed: return Text("Download failed")
        case nil: return Text("Not downloaded")
        }
    }

    /// This message's video is the one playing (or paused) in place.
    private var playsInline: Bool {
        guard case .video = message.content, !isGif else { return false }
        return model.video.isCurrent(key)
    }

    private var isGif: Bool {
        if case .video(_, _, _, true, _) = message.content { true } else { false }
    }

    /// A round video message.
    private var isNote: Bool {
        if case .video(_, _, _, _, true) = message.content { true } else { false }
    }

    private var isAnimatedSticker: Bool {
        if case .sticker(_, true) = message.content { true } else { false }
    }

    /// Animations play under the pointer while the window is in front,
    /// and not at all with Reduce Motion on.
    private var moves: Bool {
        hovering && activeState != .inactive && media.path != nil && !reduceMotion
    }

    private var shape: AnyShape {
        if isNote { return AnyShape(Circle()) }
        return AnyShape(RoundedRectangle(cornerRadius: sticker ? 0 : Metrics.bubbleRadius - Metrics.xs, style: .continuous))
    }

    private var displaySize: CGSize {
        if isNote { return CGSize(width: 220, height: 220) }
        let bound: CGFloat = sticker ? 160 : 300
        guard let width = media.width, let height = media.height, width > 0, height > 0 else {
            return CGSize(width: bound, height: sticker ? bound : bound * 0.66)
        }
        let scale = min(bound / CGFloat(width), bound / CGFloat(height), 1.5)
        return CGSize(width: max(120, CGFloat(width) * scale), height: max(80, CGFloat(height) * scale))
    }

    private func load(_ size: CGSize) async {
        let points = max(size.width, size.height)
        if let path = media.path, media.mime.hasPrefix("image") {
            image = await Thumbnails.load(URL(filePath: path), points: points)
        } else if let thumbnail = message.thumbnail {
            image = await Thumbnails.load(thumbnail, key: "thumb-\(message.id)", points: points)
        }
        model.autoDownload(message)
    }

    /// A round video message plays in place (downloading first); photos,
    /// videos and GIFs open in the media viewer; a sticker in Quick Look.
    private func activate() {
        if isNote {
            model.playVideo(message)
        } else if MediaGallery.kind(of: message) != nil {
            // Photos, videos and GIFs open in the media viewer, which
            // downloads what is not here yet.
            model.openMediaViewer(message)
        } else if let url = message.mediaURL {
            QuickLook.shared.show([url])
        } else {
            model.download(message)
        }
    }
}

private struct DownloadBadge: View {
    let state: DownloadState?
    let size: UInt64

    var body: some View {
        Group {
            switch state {
            case .downloading:
                ProgressView().controlSize(.small).tint(.white)
            case .failed:
                Label("Retry", systemImage: "arrow.clockwise")
            case nil:
                Label(
                    size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : String(localized: "Download"),
                    systemImage: "arrow.down.circle.fill"
                )
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Metrics.s).padding(.vertical, Metrics.xs)
        .background(.black.opacity(0.5), in: Capsule())
        .foregroundStyle(.white)
    }
}

/// A document: its first page when there is one to show (the sender's
/// preview, or a PDF's cover once here), then the file's own icon as the
/// Finder draws it, its name, and its pages, size and kind.
private struct DocumentContent: View {
    let message: MessageRecord
    let media: MediaInfo
    let fileName: String
    let pages: UInt32?
    let model: AppModel

    @State private var preview: NSImage?

    private static let width: CGFloat = 280
    private static let previewHeight: CGFloat = 150

    var body: some View {
        let state = model.conversations.download(MessageKey(chat: message.chat, message: message.id))
        Button(action: activate) {
            VStack(spacing: 0) {
                // The page's room is kept from the start: the timeline
                // measures a row once, before the picture has loaded.
                if hasPreview {
                    Rectangle()
                        .fill(.white)
                        .frame(width: Self.width, height: Self.previewHeight)
                        .overlay(alignment: .top) {
                            if let preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: Self.width)
                                    .transition(.opacity)
                            }
                        }
                        .clipped()
                        .overlay(alignment: .bottom) { Divider() }
                        .accessibilityHidden(true)
                }
                HStack(spacing: Metrics.s) {
                    Image(nsImage: FileIcons.icon(fileName: fileName, mime: media.mime))
                        .resizable()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileName).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(detail).font(.caption).opacity(0.75)
                    }
                    Spacer(minLength: Metrics.s)
                    if media.path == nil {
                        if state == .downloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle").font(.title3)
                                .accessibilityLabel("Download")
                        }
                    }
                }
                .padding(Metrics.s)
            }
            .frame(width: Self.width)
            .background(Palette.quoteBar.opacity(0.5))
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect(cornerRadius: Metrics.controlRadius))
        }
        .buttonStyle(.plain)
        .draggableAttachment(message)
        .task(id: "\(message.id)-\(media.path ?? "")") { await load() }
    }

    private var detail: String {
        var parts: [String] = []
        if let pages {
            parts.append(String(AttributedString(localized: "^[\(pages) page](inflect: true)").characters))
        }
        if media.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(media.size), countStyle: .file)) }
        if let ext = fileName.split(separator: ".").last, ext.count <= 5 { parts.append(ext.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// A page to show: the sender's preview, or a PDF that is here.
    private var hasPreview: Bool {
        message.thumbnail != nil
            || (message.mediaURL != nil && DocumentType.of(fileName: fileName, mime: media.mime).conforms(to: .pdf))
    }

    private func load() async {
        model.autoDownload(message)
        // A page is taller than wide and shows at full width, top first.
        let tall = Self.width * 1.5
        if let url = message.mediaURL, DocumentType.of(fileName: fileName, mime: media.mime).conforms(to: .pdf),
           let page = await Thumbnails.document(url, size: CGSize(width: Self.width, height: tall)) {
            // The file itself draws sharper than the sender's small preview.
            withAnimation(.easeOut(duration: 0.15)) { preview = page }
        } else if let thumbnail = message.thumbnail {
            preview = await Thumbnails.load(thumbnail, key: "document-\(message.id)", points: tall)
        }
    }

    private func activate() {
        if let url = message.mediaURL { QuickLook.shared.show([url]) } else { model.download(message) }
    }
}

private struct AudioContent: View {
    let message: MessageRecord
    let media: MediaInfo
    let seconds: UInt32?
    let voiceNote: Bool
    let waveform: Data
    let model: AppModel
    let footer: AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let waveWidth: CGFloat = 170
    private static let sideWidth: CGFloat = 40

    /// The play button, the waveform with the duration and time under it,
    /// and at the end the recorder's photo, which the speed control takes
    /// over while the message plays, as on the phone.
    var body: some View {
        let key = MessageKey(chat: message.chat, message: message.id)
        let player = model.voice
        let current = player.isCurrent(key)
        let downloading = model.conversations.download(key) == .downloading
        let showsAvatar = voiceNote && model.preferences.voiceAvatars
        let showsSpeed = current && voiceNote
        HStack(spacing: Metrics.s) {
            Button { model.playAudio(message) } label: {
                Group {
                    if downloading || player.preparing == key {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol(current: current, playing: player.isPlaying))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 30))
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label(current: current, playing: player.isPlaying))

            VStack(alignment: .leading, spacing: 2) {
                WaveformView(samples: Array(waveform), progress: player.progress(of: key)) { fraction in
                    model.seekAudio(message, to: fraction)
                }
                .frame(width: Self.waveWidth, height: 26)

                HStack(alignment: .firstTextBaseline, spacing: Metrics.s) {
                    Text(timeLabel(current: current))
                        .font(.caption.monospacedDigit())
                        .opacity(0.8)
                    Spacer(minLength: 0)
                    footer
                }
                .frame(width: Self.waveWidth)
            }
            .padding(.top, Metrics.xs)

            if showsSpeed || showsAvatar {
                ZStack {
                    if showsSpeed {
                        Button { model.cycleVoiceSpeed() } label: {
                            Text(speedLabel)
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .frame(width: Self.sideWidth, height: 26)
                                .background(.quaternary, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Playback speed")
                        .accessibilityLabel("Playback speed")
                        .accessibilityValue(Text(verbatim: speedLabel))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        RecorderAvatar(message: message, model: model)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .frame(width: Self.sideWidth, height: Self.sideWidth)
                .animation(.zf(reduceMotion), value: showsSpeed)
            }
        }
        .task(id: message.id) { model.autoDownload(message) }
    }

    private func symbol(current: Bool, playing: Bool) -> String {
        if media.path == nil { return "arrow.down.circle.fill" }
        return current && playing ? "pause.circle.fill" : "play.circle.fill"
    }

    private func label(current: Bool, playing: Bool) -> Text {
        if media.path == nil { return Text("Download") }
        return current && playing ? Text("Pause") : Text("Play")
    }

    private func timeLabel(current: Bool) -> String {
        let total = seconds.map(TimeInterval.init) ?? model.voice.duration
        let shown = current && model.voice.position > 0 ? model.voice.position : total
        return Duration.seconds(Int(shown.rounded(.down))).formatted(.time(pattern: .minuteSecond))
    }

    private var speedLabel: String {
        let speed = model.preferences.voiceSpeed
        return speed == 1 ? "1×" : speed == 2 ? "2×" : "1.5×"
    }
}

/// Who recorded a voice message, with a microphone on the photo as on the
/// phone: blue once ours was played, the accent colour on theirs.
private struct RecorderAvatar: View {
    let message: MessageRecord
    let model: AppModel
    @Environment(\.chatTheme) private var theme

    var body: some View {
        let id = message.fromMe ? model.session.account?.id ?? message.sender : message.sender
        let name = message.fromMe
            ? model.session.account?.name ?? ""
            : model.chats.personName(message.sender, hint: message.senderName)
        AvatarView(
            url: model.avatars.url(for: id),
            seed: id,
            placeholder: .initials(String(name.trimmingPrefix("~"))),
            size: 40,
            version: model.avatars.version(for: id)
        )
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(micColor)
                .shadow(color: .black.opacity(0.35), radius: 1)
                .offset(x: 1, y: 2)
        }
        .accessibilityHidden(true)
    }

    private var micColor: Color {
        if message.fromMe { return message.status == .played ? theme.readTicks : theme.outgoingText.opacity(0.8) }
        return theme.accent
    }
}

/// The sender's 64-bar waveform; bars before `progress` are drawn solid.
/// Clicking or dragging seeks.
private struct WaveformView: View {
    let samples: [UInt8]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let bars = samples.isEmpty ? Array(repeating: UInt8(20), count: 40) : samples
                let step = size.width / CGFloat(bars.count)
                for (index, sample) in bars.enumerated() {
                    let height = max(2, size.height * CGFloat(sample) / 100)
                    let rect = CGRect(
                        x: CGFloat(index) * step,
                        y: (size.height - height) / 2,
                        width: max(1.5, step * 0.55),
                        height: height
                    )
                    let played = (CGFloat(index) + 0.5) / CGFloat(bars.count) <= progress
                    var bar = context
                    bar.opacity = played ? 1 : 0.4
                    bar.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                seek(Double(value.location.x / max(1, proxy.size.width)))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Voice message")
        .accessibilityValue(Text("\(Int(progress * 100)) percent played"))
        // VoiceOver and the keyboard move through it a tenth at a time.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(1, progress + 0.1))
            case .decrement: seek(max(0, progress - 0.1))
            @unknown default: break
            }
        }
    }
}

/// A place: the sender's map picture when there is one, a pin and the
/// place's name, and for a live location when it last moved, how fast and
/// how precisely (upstream's `location_card`). A click opens it in Maps.
private struct LocationContent: View {
    let message: MessageRecord
    let latitude: Double
    let longitude: Double
    let title: String
    let detail: String?
    let live: Bool
    let model: AppModel
    /// A live location's latest update, so its picture is reloaded.
    var version: Int64 = 0

    @State private var picture: NSImage?

    private static let width: CGFloat = 260
    private static let previewHeight: CGFloat = 146

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                // Room kept from the start, as the row is measured once.
                if message.thumbnail != nil {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: Self.width, height: Self.previewHeight)
                        .overlay {
                            if let picture {
                                Image(nsImage: picture)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: Self.width, height: Self.previewHeight)
                            }
                        }
                        .overlay {
                            Image(systemName: live ? "location.circle.fill" : "mappin.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white, live ? Color.blue : Color.red)
                                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        }
                        .clipped()
                        .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: Metrics.s) {
                    Image(systemName: live ? "location.fill" : "mappin.and.ellipse")
                        .foregroundStyle(live ? AnyShapeStyle(.blue) : AnyShapeStyle(.tint))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body.weight(.medium)).lineLimit(2)
                        if let detail {
                            Text(detail).font(.caption).opacity(0.75).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(Metrics.s)
            }
            .frame(width: Self.width)
            .background(Palette.quoteBar.opacity(0.5))
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect(cornerRadius: Metrics.controlRadius))
        }
        .buttonStyle(.plain)
        .help("Open in Maps")
        .task(id: "\(message.id)-\(version)") {
            guard let thumbnail = message.thumbnail else { return }
            picture = await Thumbnails.load(thumbnail, key: "map-\(message.id)-\(version)", points: Self.width)
        }
    }

    /// "Updated 14:05 · 31 km/h · ±12 m", as upstream words a live location.
    static func liveDetail(updated: Int64, speed: Float?, accuracy: UInt32?) -> String? {
        var parts: [String] = []
        if updated > 0 {
            parts.append(String(localized: "Updated \(DateText.bubble(updated))"))
        }
        if let speed, speed >= 0.5 {
            let kmh = Measurement(value: Double(speed), unit: UnitSpeed.metersPerSecond).converted(to: .kilometersPerHour)
            parts.append(kmh.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))))
        }
        if let accuracy, accuracy > 0 {
            parts.append("±\(accuracy) m")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func open() {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
        if !live, title != String(localized: "Location") {
            components.queryItems?.append(URLQueryItem(name: "q", value: title))
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
