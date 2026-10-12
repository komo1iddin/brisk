import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// A list button's choices, grouped by section; picking one and Send
/// answers the message (upstream's list dialog).
struct InteractiveListSheet: View {
    let request: InteractiveListRequest
    let model: AppModel
    @State private var choice: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text(button?.label ?? String(localized: "Choose an Option")).font(.headline)
            if let message, case .select(let options) = button?.action {
                List(selection: $choice) {
                    ForEach(sections(options), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.rows, id: \.index) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.option.title)
                                    if !row.option.description.isEmpty {
                                        Text(row.option.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(row.index)
                            }
                        }
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)
                .frame(minHeight: 240, maxHeight: 420)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Send") {
                        if let choice { model.answer(message, button: request.button, choice: choice) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil || !model.canAnswer(message))
                }
            } else {
                Text("This message is no longer available.").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
    }

    private var message: MessageRecord? {
        model.loadedMessage(chat: request.key.chat, id: request.key.message)
    }

    private var button: InteractiveButtonInfo? {
        guard let message, case .interactive(_, let card?) = message.content,
              card.buttons.indices.contains(request.button) else { return nil }
        return card.buttons[request.button]
    }

    private struct Row {
        let index: Int
        let option: InteractiveOptionInfo
    }

    /// Sections in first-seen order; the index is the option's place in
    /// the whole list, which is what the worker resolves.
    private func sections(_ options: [InteractiveOptionInfo]) -> [(title: String, rows: [Row])] {
        var result: [(title: String, rows: [Row])] = []
        for (index, option) in options.enumerated() {
            let row = Row(index: index, option: option)
            if let at = result.firstIndex(where: { $0.title == option.section }) {
                result[at].rows.append(row)
            } else {
                result.append((option.section, [row]))
            }
        }
        return result
    }
}
