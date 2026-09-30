import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The bubble: sender name, forwarded label, quote, content, and footer.
struct MessageBubble: View {
    let message: MessageRecord
    let senderName: String?
    let model: AppModel
    @Environment(\.chatTheme) private var theme

    var body: some View {
        BubbleStack(spacing: Metrics.xs) {
            if let senderName {
                Text(senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.sender(message.sender))
                    .lineLimit(1)
                    .insetForMedia(isMedia)
            }
            if message.forwarded {
                Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                    .font(.caption.italic())
                    .foregroundStyle(secondaryText)
                    .insetForMedia(isMedia)
            }
            if let quoted = message.quoted {
                QuoteView(quoted: quoted, fromMe: message.fromMe, textColor: primaryText, model: model) {
                    model.showQuoted(in: message)
                }
            }
            if let text = inlineFooterText {
                // The time tucks into the last line, as on the phone: the
                // text reserves room for it and the footer sits over that room.
                BodyText(text: text, message: message, model: model, reserve: footerReserve)
                    .overlay(alignment: .bottomTrailing) { footer.alignmentGuide(.bottom) { $0[.bottom] - 2 } }
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
                RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous)
                    .fill(message.fromMe ? theme.outgoing : theme.incoming)
                    // Over a wallpaper bubbles lift a little, as on the phone.
                    .shadow(color: .black.opacity(theme.hasWallpaper ? 0.1 : 0), radius: 0.5, y: 0.5)
            }
        }
        .foregroundStyle(primaryText)
        .tint(message.fromMe ? theme.outgoingText : theme.accent)
    }

    /// Photos and videos run almost to the bubble's edge.
    private var isMedia: Bool {
        switch message.content {
        case .image, .video: true
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
    let fromMe: Bool
    /// Our bubble's text colour, which its quote's bar and name take.
    let textColor: Color
    let model: AppModel
    let show: () -> Void

    var body: some View {
        HStack(spacing: Metrics.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fromMe ? textColor : Palette.sender(quoted.sender))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.chats.displayName(quoted.sender, hint: quoted.senderName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(fromMe ? textColor : Palette.sender(quoted.sender))
                Text(quoted.summary)
                    .font(.callout)
                    .lineLimit(2)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.s)
        .background(Palette.quoteBar.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
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
