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
                if let preview { LinkPreviewCard(preview: preview, thumbnail: message.thumbnail, key: message.id, chat: message.chat, model: model) }
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
                title: name ?? String(localized: "Location"), detail: address, live: false, model: model,
                inset: captionInset
            )
        case let .liveLocation(latitude, longitude, accuracy, speed, _, ended, updated):
            LocationContent(
                message: message, latitude: latitude, longitude: longitude,
                title: ended ? String(localized: "Live location ended") : String(localized: "Live location"),
                detail: LocationContent.liveDetail(updated: updated, speed: speed, accuracy: accuracy),
                live: !ended, model: model, version: updated, inset: captionInset
            )
        case let .contact(displayName, vcard):
            ContactCard(message: message, displayName: displayName, vcard: vcard, model: model)
        case let .poll(question, options, state):
            PollContent(message: message, question: question, options: options, state: state, model: model)
        case let .stickerPack(name, publisher, count, caption):
            VStack(alignment: .leading, spacing: Metrics.xs) {
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
                    .background(Palette.inset, in: .rect(cornerRadius: Metrics.controlRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 220)
                .help("View the stickers")
                // The words sent with the pack, as upstream shows them.
                if let caption, !caption.isEmpty {
                    Text(WhatsAppMarkup.attributed(caption, mentions: message.mentions, name: { model.chats.displayName($0) }))
                        .textSelection(.enabled)
                }
            }
        case .revoked:
            Placeholder(symbol: "nosign", text: String(localized: "This message was deleted"))
        case .unsupported(let what):
            Placeholder(symbol: "exclamationmark.triangle", text: what)
        case let .phoneOnly(viewOnce, liveLocation, once):
            Placeholder(
                symbol: "iphone",
                text: PhoneOnlyText.text(viewOnce: viewOnce, liveLocation: liveLocation, once: once)
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
