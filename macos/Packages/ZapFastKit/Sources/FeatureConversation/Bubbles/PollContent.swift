import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A poll in its bubble: the question, one row per option with its count
/// and bar, and a line on the voting state. Clicking an option votes, as
/// upstream's ballot does.
struct PollContent: View {
    let message: MessageRecord
    let question: String
    let options: [String]
    let state: PollSummary
    let model: AppModel

    var body: some View {
        let pending = model.pollVoting.contains(key)
        let active = state.canVote && model.session.isConnected && !pending
        VStack(alignment: .leading, spacing: Metrics.s) {
            VStack(alignment: .leading, spacing: Metrics.xxs) {
                Text(question)
                    .font(.body.weight(.semibold))
                Text(state.selectable == 1 ? "Select one answer" : "Select answers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                OptionRow(
                    option: option,
                    count: state.counts.indices.contains(index) ? Int(state.counts[index]) : 0,
                    voters: Int(state.voters),
                    chosen: state.selected.contains(UInt32(index)),
                    active: active
                ) {
                    model.vote(message, option: index)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(detail(pending: pending))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Metrics.s)
                if state.voters > 0 {
                    Button("View Votes") { model.showPollResults(message) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(minWidth: 240)
        .onAppear { model.pollAppeared(message) }
    }

    private var key: MessageKey {
        MessageKey(chat: message.chat, message: message.id)
    }

    /// Upstream's status line under the ballot.
    private func detail(pending: Bool) -> String {
        if pending { return String(localized: "Sending vote…") }
        if !state.canVote { return String(localized: "Voting key unavailable, use your phone") }
        if !model.session.isConnected { return String(localized: "Reconnect to vote") }
        if state.refreshFailed { return String(localized: "Waiting for your phone, earlier votes may be missing") }
        if !state.historyComplete {
            return state.refreshing
                ? String(localized: "Loading earlier votes from your phone…")
                : String(localized: "Earlier votes have not been loaded yet")
        }
        return state.voters == 1 ? String(localized: "1 voter") : String(localized: "\(state.voters) voters")
    }
}

private struct OptionRow: View {
    let option: String
    let count: Int
    let voters: Int
    let chosen: Bool
    let active: Bool
    let vote: () -> Void

    var body: some View {
        Button(action: vote) {
            HStack(alignment: .top, spacing: Metrics.s) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.body)
                VStack(alignment: .leading, spacing: Metrics.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(option)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Metrics.s)
                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Capsule()
                        .fill(.secondary.opacity(0.25))
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .frame(width: proxy.size.width * fraction)
                            }
                        }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Not `.disabled`: the results stay readable when voting is not
        // possible; the line under the ballot says why.
        .allowsHitTesting(active)
        .accessibilityRespondsToUserInteraction(active)
        .accessibilityLabel(Text(option))
        .accessibilityValue(Text(count == 1 ? "1 vote" : "\(count) votes"))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Share of the people who voted, as upstream draws it.
    private var fraction: CGFloat {
        guard voters > 0 else { return 0 }
        return min(1, CGFloat(count) / CGFloat(voters))
    }
}
