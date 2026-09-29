import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// What a message holds, drawn by kind.
struct MessageContentView: View {
    let message: MessageRecord
    let model: AppModel
    let textColor: Color
    /// Captions under edge-to-edge media keep the usual text inset.
    var captionInset = false

    var body: some View {
        switch message.content {
        case let .text(text, preview):
            VStack(alignment: .leading, spacing: Metrics.s) {
                BodyText(text: text, message: message, model: model)
                if let preview { LinkPreviewCard(preview: preview, thumbnail: message.thumbnail, key: message.id) }
            }
        case let .interactive(text, _):
            BodyText(text: text, message: message, model: model)
        case let .image(caption, media):
            VisualMedia(message: message, media: media, symbol: "photo", model: model)
            caption.map { BodyText(text: $0, message: message, model: model).insetForMedia(captionInset) }
        case let .video(caption, media, seconds, _, _):
            VisualMedia(message: message, media: media, symbol: "play.circle.fill", model: model, seconds: seconds)
            caption.map { BodyText(text: $0, message: message, model: model).insetForMedia(captionInset) }
        case let .sticker(media, _):
            VisualMedia(message: message, media: media, symbol: "face.smiling", model: model, sticker: true)
        case let .audio(media, seconds, voiceNote, waveform):
            AudioContent(message: message, media: media, seconds: seconds, voiceNote: voiceNote, waveform: waveform, model: model)
        case let .document(media, fileName, caption, pages):
            DocumentContent(message: message, media: media, fileName: fileName, pages: pages, model: model)
            caption.map { BodyText(text: $0, message: message, model: model) }
        case let .location(latitude, longitude, name, address):
            LocationContent(latitude: latitude, longitude: longitude, title: name, detail: address, live: false)
        case let .liveLocation(latitude, longitude, _, _, _, ended, _):
            LocationContent(
                latitude: latitude, longitude: longitude,
                title: String(localized: ended ? "Live location ended" : "Live location"),
                detail: nil, live: !ended
            )
        case let .contact(displayName, _):
            Label(displayName, systemImage: "person.crop.circle")
                .font(.body.weight(.medium))
        case let .poll(question, options, state):
            PollContent(question: question, options: options, state: state)
        case let .stickerPack(name, publisher, count, _):
            Label {
                VStack(alignment: .leading) {
                    Text(name).font(.body.weight(.medium))
                    Text("\(publisher) · \(count) stickers").font(.caption).opacity(0.8)
                }
            } icon: {
                Image(systemName: "face.smiling")
            }
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

    var body: some View {
        let styled = Text(WhatsAppMarkup.attributed(
            text,
            mentions: message.mentions,
            name: { model.chats.displayName($0) }
        ))
        let spaced = reserve.map { styled + Text($0).font(.caption2.monospacedDigit()).foregroundStyle(.clear) } ?? styled
        spaced
        .font(Self.isOnlyEmoji(text) ? .system(size: 40) : .body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Link preview

private struct LinkPreviewCard: View {
    let preview: LinkPreviewInfo
    let thumbnail: Data?
    let key: String

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
        .onTapGesture {
            if let url = URL(string: preview.url) { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: - Media

/// Photos, videos, and stickers: the preview at the picture's shape, a
/// download button until the file is here, then a click opens it.
private struct VisualMedia: View {
    let message: MessageRecord
    let media: MediaInfo
    let symbol: String
    let model: AppModel
    var seconds: UInt32?
    var sticker = false

    @State private var image: NSImage?

    var body: some View {
        let size = displaySize
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                if media.path != nil || sticker {
                    Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            overlay
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: sticker ? 0 : Metrics.bubbleRadius - Metrics.xs, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: activate)
        .task(id: "\(message.id)-\(media.path ?? "")") { await load(size) }
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var overlay: some View {
        let state = model.conversations.downloads[MessageKey(chat: message.chat, message: message.id)]
        if media.path == nil, !sticker {
            DownloadBadge(state: state, size: media.size)
        } else if case .video = message.content {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white, .black.opacity(0.35))
        }
        if let seconds, seconds > 0 {
            Text(Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond)))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(Metrics.s)
        }
    }

    private var displaySize: CGSize {
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
        // Stickers are small; fetch them straight away, as the phone does.
        if sticker, media.path == nil { model.download(message) }
    }

    private func activate() {
        if let url = message.mediaURL {
            NSWorkspace.shared.open(url)
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

private struct DocumentContent: View {
    let message: MessageRecord
    let media: MediaInfo
    let fileName: String
    let pages: UInt32?
    let model: AppModel

    var body: some View {
        let state = model.conversations.downloads[MessageKey(chat: message.chat, message: message.id)]
        Button(action: activate) {
            HStack(spacing: Metrics.s) {
                Image(systemName: "doc.fill").font(.title2)
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
                    }
                }
            }
            .padding(Metrics.s)
            .background(Palette.quoteBar.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 220)
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

    private func activate() {
        if let url = message.mediaURL { NSWorkspace.shared.open(url) } else { model.download(message) }
    }
}

private struct AudioContent: View {
    let message: MessageRecord
    let media: MediaInfo
    let seconds: UInt32?
    let voiceNote: Bool
    let waveform: Data
    let model: AppModel

    var body: some View {
        let state = model.conversations.downloads[MessageKey(chat: message.chat, message: message.id)]
        HStack(spacing: Metrics.s) {
            Button(action: activate) {
                Group {
                    if state == .downloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: media.path == nil ? "arrow.down.circle.fill" : "play.circle.fill")
                    }
                }
                .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(media.path == nil ? Text("Download") : Text("Play"))

            WaveformView(samples: Array(waveform))
                .frame(width: 150, height: 24)

            if let seconds {
                Text(Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .opacity(0.8)
            }
        }
    }

    private func activate() {
        if let url = message.mediaURL { NSWorkspace.shared.open(url) } else { model.download(message) }
    }
}

private struct WaveformView: View {
    let samples: [UInt8]

    var body: some View {
        Canvas { context, size in
            let bars = samples.isEmpty ? Array(repeating: UInt8(20), count: 40) : samples
            let step = size.width / CGFloat(bars.count)
            for (index, sample) in bars.enumerated() {
                let height = max(2, size.height * CGFloat(sample) / 100)
                let rect = CGRect(
                    x: CGFloat(index) * step,
                    y: (size.height - height) / 2,
                    width: max(1, step * 0.6),
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .foreground)
            }
        }
        .opacity(0.7)
        .accessibilityHidden(true)
    }
}

private struct LocationContent: View {
    let latitude: Double
    let longitude: Double
    let title: String?
    let detail: String?
    let live: Bool

    var body: some View {
        Button {
            if let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? String(localized: "Location")).font(.body.weight(.medium))
                    if let detail { Text(detail).font(.caption).opacity(0.8) }
                }
            } icon: {
                Image(systemName: live ? "location.fill" : "map")
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PollContent: View {
    let question: String
    let options: [String]
    let state: PollSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Label(question, systemImage: "chart.bar")
                .font(.body.weight(.semibold))
            let total = max(1, state.counts.reduce(0, +))
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let count = index < state.counts.count ? state.counts[index] : 0
                let chosen = state.selected.contains(UInt32(index))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        Text(option)
                        Spacer()
                        Text("\(count)").monospacedDigit()
                    }
                    .font(.callout)
                    ProgressView(value: Double(count), total: Double(total))
                        .progressViewStyle(.linear)
                }
            }
            Text("\(state.voters) votes").font(.caption).opacity(0.75)
        }
        .frame(minWidth: 220)
    }
}
