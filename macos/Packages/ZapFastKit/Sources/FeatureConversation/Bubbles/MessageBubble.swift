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

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.xs) {
            if let senderName {
                Text(senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.sender(message.sender))
                    .lineLimit(1)
            }
            if message.forwarded {
                Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                    .font(.caption.italic())
                    .foregroundStyle(secondaryText)
            }
            if let quoted = message.quoted {
                QuoteView(quoted: quoted, fromMe: message.fromMe, model: model)
            }
            MessageContentView(message: message, model: model, textColor: primaryText)
            footer
        }
        .padding(.horizontal, isBare ? 0 : Metrics.m)
        .padding(.vertical, isBare ? 0 : Metrics.s)
        .background {
            if !isBare {
                RoundedRectangle(cornerRadius: Metrics.bubbleRadius, style: .continuous)
                    .fill(message.fromMe ? Palette.bubbleOutgoing : Palette.bubbleIncoming)
            }
        }
        .foregroundStyle(primaryText)
        .tint(message.fromMe ? Palette.bubbleOutgoingText : Color.accentColor)
    }

    /// Stickers float without a bubble, as on the phone.
    private var isBare: Bool {
        if case .sticker = message.content { true } else { false }
    }

    private var primaryText: Color {
        message.fromMe && !isBare ? Palette.bubbleOutgoingText : Color.primary
    }

    private var secondaryText: Color {
        message.fromMe && !isBare ? Palette.bubbleOutgoingText.opacity(0.75) : Color.secondary
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
                    readTint: isBare ? .accentColor : Palette.bubbleOutgoingText
                )
            }
        }
        .font(.caption2)
        .foregroundStyle(secondaryText)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, isBare ? Metrics.s : 0)
        .background {
            if isBare { Capsule().fill(.regularMaterial) }
        }
    }
}

/// The replied-to message, with a bar in the sender's colour.
private struct QuoteView: View {
    let quoted: QuotedMessage
    let fromMe: Bool
    let model: AppModel

    var body: some View {
        HStack(spacing: Metrics.s) {
            RoundedRectangle(cornerRadius: 2)
                .fill(fromMe ? Palette.bubbleOutgoingText : Palette.sender(quoted.sender))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.chats.displayName(quoted.sender, hint: quoted.senderName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(fromMe ? Palette.bubbleOutgoingText : Palette.sender(quoted.sender))
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
    }
}

