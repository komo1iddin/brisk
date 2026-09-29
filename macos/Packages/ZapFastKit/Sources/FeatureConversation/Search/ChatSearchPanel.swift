import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The inspector that searches the open chat: a field, the matches newest
/// first, and a note when the archive held more than are listed. Picking a
/// match scrolls the timeline to it.
struct ChatSearchPanel: View {
    let search: ChatSearch
    let model: AppModel
    @State private var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: Binding(get: { search.query }, set: { model.setChatSearchQuery($0) }),
                prompt: String(localized: "Search this chat"),
                focusRequest: focusRequest,
                onSubmit: { model.revealChatSearchHit(search.selected ?? 0) },
                onMove: { down in model.stepChatSearch(older: down) },
                onEscape: { model.closeChatSearch() }
            )
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.s)

            Divider()

            results
                .frame(maxHeight: .infinity)
        }
        .onChange(of: model.chatSearchFocusRequests, initial: true) { focusRequest += 1 }
    }

    @ViewBuilder private var results: some View {
        let query = search.trimmedQuery
        if query.isEmpty {
            ContentUnavailableView(
                "Search this chat",
                systemImage: "magnifyingglass",
                description: Text("Find messages by the words in them.")
            )
        } else if search.hits.isEmpty {
            if search.pending {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            List(selection: selection) {
                ForEach(Array(search.hits.enumerated()), id: \.element.id) { index, hit in
                    HitRow(message: hit, query: query, model: model)
                        .tag(index)
                }
                if search.truncated {
                    Text("Only the newest \(search.hits.count) matches are listed. Add a word to narrow the search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            .listStyle(.inset)
        }
    }

    private var selection: Binding<Int?> {
        Binding(
            get: { search.selected },
            set: { index in
                if let index { model.revealChatSearchHit(index) }
            }
        )
    }
}

/// One match: who wrote it and when, and the text around the match.
private struct HitRow: View {
    let message: MessageRecord
    let query: String
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(sender)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: Metrics.xs)
                Text(DateText.chatRow(message.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(SearchSnippet.make(model.messageText(message), matching: query))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, Metrics.xxs)
        .accessibilityElement(children: .combine)
    }

    private var sender: String {
        message.fromMe
            ? String(localized: "You")
            : model.chats.displayName(message.sender, hint: message.senderName)
    }
}
