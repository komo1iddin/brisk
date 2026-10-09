import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// "Message info" (upstream's `ui/message_info.rs`): when one of our
/// messages was delivered and read. A group lists each member, from the
/// receipts the backend follows while the sheet is open; a direct chat has
/// the times its ticks turned.
struct MessageInfoSheet: View {
    let key: MessageKey
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Message Info").font(.headline)
            if let message = model.conversations.conversation(key.chat).message(key.message) {
                Preview(message: message, model: model)
                if model.chats.chat(key.chat)?.kind == .group {
                    GroupReceipts(receipts: model.receipts, model: model)
                } else {
                    DirectReceipts(message: message)
                }
            } else {
                Text("This message is no longer available.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
    }
}

/// The message as a short outgoing bubble, with its time and ticks.
private struct Preview: View {
    let message: MessageRecord
    let model: AppModel
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: Metrics.xxs) {
                Text(model.messageText(message))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                HStack(spacing: Metrics.xs) {
                    Text(DateText.bubble(message.timestamp)).monospacedDigit()
                    DeliveryTicks(DeliveryTicks.State(message.status), readTint: theme.readTicks)
                }
                .font(.caption2)
                .foregroundStyle(theme.outgoingText.opacity(0.7))
            }
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.s)
            .foregroundStyle(theme.outgoingText)
            .background(theme.outgoing, in: .rect(cornerRadius: Metrics.bubbleRadius, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A direct chat's one recipient: the times its ticks turned.
private struct DirectReceipts: View {
    let message: MessageRecord

    var body: some View {
        let played = message.status == .played
        let read = played || message.status == .read
        let delivered = read || message.status == .delivered
        Form {
            stage(played ? "Played" : "Read", reached: read, at: message.readAt, color: .accentColor)
            stage("Delivered", reached: delivered, at: message.deliveredAt, color: .secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 130)
    }

    private func stage(_ title: LocalizedStringKey, reached: Bool, at: Int64?, color: Color) -> some View {
        LabeledContent {
            Group {
                if !reached {
                    Text(verbatim: "—")
                } else if let at = known(at) {
                    Text(DateText.moment(at))
                } else {
                    Text("Time not recorded")
                }
            }
            .foregroundStyle(.secondary)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
            }
        }
    }
}

/// A group's members sorted into Played by, Read by and Delivered to.
private struct GroupReceipts: View {
    let receipts: MessageReceiptsInfo?
    let model: AppModel

    var body: some View {
        if let receipts {
            if !receipts.recorded {
                note("No receipts were recorded for this message. Details are available for messages sent from now on.")
            } else {
                if !receipts.audienceKnown {
                    note("Some receipts for this message were not recorded. Details are complete for messages sent from now on.")
                }
                List {
                    if !receipts.played.isEmpty {
                        section("Played by", receipts.played, at: \.playedAt)
                    }
                    section("Read by", receipts.read, at: \.readAt)
                    section("Delivered to", receipts.delivered, at: \.deliveredAt)
                    if receipts.remaining > 0 {
                        Text("\(receipts.remaining) remaining")
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .frame(minHeight: 280)
            }
        } else {
            HStack(spacing: Metrics.s) {
                ProgressView().controlSize(.small)
                Text("Loading…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section(
        _ title: LocalizedStringKey,
        _ recipients: [RecipientInfo],
        at: KeyPath<RecipientInfo, Int64?>
    ) -> some View {
        Section(title) {
            if recipients.isEmpty {
                Text("No one yet").foregroundStyle(.secondary)
            }
            ForEach(recipients, id: \.id) { recipient in
                let name = model.chats.displayName(recipient.id)
                HStack(spacing: Metrics.s) {
                    AvatarView(
                        url: model.avatars.url(for: recipient.id),
                        seed: recipient.id,
                        placeholder: .initials(String(name.trimmingPrefix("~"))),
                        size: 28,
                        version: model.avatars.version(for: recipient.id)
                    )
                    Text(name).lineLimit(1)
                    Spacer()
                    if let time = known(recipient[keyPath: at]) {
                        Text(DateText.moment(time))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A receipt time of zero or less is unknown, not 1 January 1970: archives
/// filed before upstream stopped dating receipts from history hold zeros
/// (upstream's `known_time`).
func known(_ time: Int64?) -> Int64? {
    time.flatMap { $0 > 0 ? $0 : nil }
}
