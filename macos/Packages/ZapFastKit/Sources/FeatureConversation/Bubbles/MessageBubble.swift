import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The bubble: sender name, forwarded label, quote, content, and footer.
struct MessageBubble: View {
    let message: MessageRecord
    let senderName: String?
    /// The last message of its run has a tail (`BubbleTail`).
    var endsRun = true
    let model: AppModel
    @Environment(\.chatTheme) private var theme
    @Environment(\.messageTextScale) private var scale

    var body: some View {
        let nameSize = TimelineText.bodyFonts(scale: scale).name.pointSize
        BubbleStack(spacing: Metrics.xs) {
            if let senderName {
                // Opens the sender's page in the chat's info, as WhatsApp does.
                Button {
                    model.showInfo(in: message.chat, person: message.sender)
                } label: {
                    HStack(spacing: TimelineGeometry.phoneGap) {
                        Text(senderName)
                            .font(.system(size: nameSize, weight: .semibold))
                            .foregroundStyle(Palette.name(model.chats.nameColor(message.sender, in: message.chat)))
                            .lineLimit(1)
                        // Beside the name of someone not saved, as WhatsApp does.
                        if model.preferences.senderPhones, let phone = model.chats.unsavedPhone(message.sender), phone != senderName {
                            Spacer(minLength: 0)
                            Text(phone)
                                .font(.system(size: nameSize))
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Show \(senderName)'s info")
                .insetForMedia(isMedia)
            }
            if message.forwarded {
                Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                    .font(.caption.italic())
                    .foregroundStyle(secondaryText)
                    .insetForMedia(isMedia)
            }
            if let quoted = message.quoted {
                QuoteView(quoted: quoted, chat: message.chat, fromMe: message.fromMe, textColor: primaryText, model: model) {
                    model.showQuoted(in: message)
                }
                // Almost to the bubble's sides, as WhatsApp's quote runs.
                .padding(.horizontal, isMedia ? 0 : TimelineGeometry.quoteInset - Metrics.m)
            }
            if let text = inlineFooterText {
                // The time tucks into the last line, as on the phone: the
                // text reserves room for it and the footer sits over that room.
                BodyText(text: text, message: message, model: model, reserve: footerReserve)
                    .overlay(alignment: .bottomTrailing) { footer.alignmentGuide(.bottom) { $0[.bottom] - 2 } }
            } else if case .audio = message.content {
                // The player puts the time beside its duration.
                MessageContentView(message: message, model: model, textColor: primaryText, footer: AnyView(footer))
            } else {
                MessageContentView(message: message, model: model, textColor: primaryText, captionInset: isMedia)
                footer
                    .insetForMedia(isMedia)
                    .bubbleTrailing()
            }
        }
        .padding(.horizontal, isBare ? 0 : isMedia ? Metrics.xs : Metrics.m)
        .padding(.top, isBare ? 0 : isMedia ? Metrics.xs : Metrics.s)
        .padding(.bottom, isBare ? 0 : Metrics.s)
        .background {
            if !isBare {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous)
                    if endsRun { BubbleTailShape(fromMe: message.fromMe) }
                }
                .foregroundStyle(message.fromMe ? theme.outgoing : theme.incoming)
                // Over a wallpaper bubbles lift a little, as on the phone.
                .shadow(color: .black.opacity(theme.hasWallpaper ? 0.1 : 0), radius: 0.5, y: 0.5)
            }
        }
        .foregroundStyle(primaryText)
        .tint(message.fromMe ? theme.outgoingText : theme.accent)
    }

    /// Photos, videos and maps run almost to the bubble's edge.
    private var isMedia: Bool {
        switch message.content {
        case .image, .video, .location, .liveLocation: true
        default: false
        }
    }

    /// Plain text whose last line can hold the time.
    private var inlineFooterText: String? {
        switch message.content {
        case .text(let text, nil) where !BodyText.isOnlyEmoji(text): text
        case .interactive(let text, nil) where !BodyText.isOnlyEmoji(text): text
        default: nil
        }
    }

    /// Invisible text as wide as the footer, appended to the message text.
    private var footerReserve: String {
        let edited = message.edited ? String(localized: "Edited") + " " : ""
        let ticks = message.fromMe ? "\u{2003}\u{2002}" : ""
        return "\u{2003}\(edited)\(DateText.bubble(message.timestamp))\(ticks)"
    }

    /// Stickers, round video messages and emoji-only text float without a
    /// bubble, as on the phone.
    private var isBare: Bool {
        switch message.content {
        case .sticker, .video(_, _, _, _, true): true
        case .text(let text, nil): message.quoted == nil && BodyText.isOnlyEmoji(text)
        default: false
        }
    }

    private var primaryText: Color {
        message.fromMe && !isBare ? theme.outgoingText : Color.primary
    }

    private var secondaryText: Color {
        message.fromMe && !isBare ? theme.outgoingText.opacity(0.7) : Color.secondary
    }

    private var footer: some View {
        HStack(spacing: Metrics.xs) {
            if message.edited {
                Text("Edited")
            }
            Text(DateText.bubble(message.timestamp))
                .monospacedDigit()
            if message.fromMe {
                DeliveryTicks(
                    DeliveryTicks.State(message.status),
                    readTint: isBare ? theme.accent : theme.readTicks
                )
            }
        }
        .font(.caption2)
        .foregroundStyle(secondaryText)
        .fixedSize()
        .padding(.horizontal, isBare ? Metrics.s : 0)
        .background {
            if isBare { Capsule().fill(.regularMaterial) }
        }
    }
}

/// The replied-to message, with a bar in the sender's colour. Clicking it
/// scrolls to the original.
private struct QuoteView: View {
    let quoted: QuotedMessage
    let chat: String
    let fromMe: Bool
    /// Our bubble's text colour, which its quote's bar and name take.
    let textColor: Color
    let model: AppModel
    let show: () -> Void

    @State private var picture: NSImage?
    @Environment(\.messageTextScale) private var scale

    var body: some View {
        let preview = QuotePreview.named(
            quoted, original: quoted.id.isEmpty ? nil : model.conversations.conversation(chat).message(quoted.id),
            name: { model.chats.displayName($0) }
        )
        let size = TimelineText.bodyFonts(scale: scale).name.pointSize
        let name = model.chats.displayName(quoted.sender, hint: quoted.senderName)
        let nameColor = Palette.name(model.chats.nameColor(quoted.sender, in: chat))
        HStack(spacing: 0) {
            // The bar is the quote's left edge, rounded with its corners.
            Rectangle()
                .fill(fromMe ? textColor : nameColor)
                .frame(width: TimelineGeometry.quoteBarWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: TimelineGeometry.phoneGap) {
                    Text(name)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(fromMe ? textColor : nameColor)
                        .lineLimit(1)
                    if model.preferences.senderPhones, model.chats.chat(chat)?.kind == .group,
                       let phone = model.chats.unsavedPhone(quoted.sender), phone != name {
                        Spacer(minLength: 0)
                        Text(phone).font(.system(size: size)).opacity(0.6).lineLimit(1).layoutPriority(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: TimelineGeometry.quoteSymbolGap) {
                    if let symbol = preview.symbol {
                        Image(systemName: symbol).font(.system(size: size - 1)).opacity(0.7)
                    }
                    Text(preview.summary)
                        .font(.system(size: size))
                        .lineLimit(TimelineGeometry.quoteSummaryLines)
                        .opacity(0.75)
                }
            }
            .padding(.horizontal, TimelineGeometry.quoteTextInset)
            .padding(.vertical, TimelineGeometry.quoteVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            if preview.thumbnail != nil {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: TimelineGeometry.quoteThumbnail)
                    .frame(minHeight: TimelineGeometry.quoteThumbnail)
                    .overlay {
                        if let picture {
                            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipped()
                    .task(id: Thumbnails.scope([model.accountID, chat, quoted.id, Thumbnails.contentID(preview.thumbnail)])) {
                        guard let data = preview.thumbnail else { return }
                        let loaded = await Thumbnails.load(data, key: Thumbnails.scope([model.accountID, chat, "quote-view", quoted.id]), points: TimelineGeometry.quoteThumbnail * 1.5)
                        guard !Task.isCancelled else { return }
                        picture = loaded
                    }
            }
        }
        .background(Palette.inset)
        .clipShape(.rect(cornerRadius: Metrics.controlRadius))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect(cornerRadius: Metrics.controlRadius))
        .onTapGesture(perform: show)
        .help("Show the original message")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the original message")
        .accessibilityAction { show() }
    }
}


extension View {
    /// Text beside edge-to-edge media keeps the usual text inset.
    func insetForMedia(_ media: Bool) -> some View {
        padding(.horizontal, media ? Metrics.s : 0)
    }
}
