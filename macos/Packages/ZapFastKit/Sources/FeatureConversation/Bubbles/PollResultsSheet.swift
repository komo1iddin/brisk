import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Who chose what in a poll, option by option, from the latest decrypted
/// votes. It reads the live message, so results update while it is open.
struct PollResultsSheet: View {
    let key: MessageKey
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Poll Results").font(.headline)
            if let (question, options, state) = poll {
                Text(question).font(.body.weight(.semibold))
                if !state.historyComplete {
                    Text("Earlier votes may still be missing. Results update as they arrive.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                List {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        section(option: option, index: index, state: state)
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .frame(minHeight: 280)
            } else {
                Text("This poll is no longer available.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
    }

    private var poll: (String, [String], PollSummary)? {
        guard let message = model.loadedMessage(chat: key.chat, id: key.message),
              case let .poll(question, options, state) = message.content else { return nil }
        return (question, options, state)
    }

    @ViewBuilder
    private func section(option: String, index: Int, state: PollSummary) -> some View {
        let count = state.counts.indices.contains(index) ? Int(state.counts[index]) : 0
        let voters = state.votes
            .filter { $0.choices.contains(UInt32(index)) }
            .sorted { $0.timestamp > $1.timestamp }
        Section {
            ForEach(voters, id: \.id) { voter in
                HStack(spacing: Metrics.s) {
                    AvatarView(
                        url: model.avatars.url(for: voter.id),
                        seed: voter.id,
                        placeholder: .initials(voter.name),
                        size: 28
                    )
                    Text(voter.fromMe ? String(localized: "You") : voter.name).lineLimit(1)
                    Spacer()
                    Text(DateText.date(voter.timestamp).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if voters.count < count {
                Text("Participant details are not available yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(option)
                Spacer()
                Text(count == 1 ? "1 vote" : "\(count) votes").monospacedDigit()
            }
        }
    }
}
