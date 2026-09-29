import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Picks the chat to forward to: a search field over the chats that can
/// receive, most recent first. Select one and Forward, or double-click it.
struct ForwardSheet: View {
    let request: ForwardRequest
    let model: AppModel

    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let targets = model.chats.forwardTargets(query: query)
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text(request.messages.count == 1 ? "Forward Message" : "Forward \(request.messages.count) Messages")
                .font(.headline)

            TextField("Search chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { selection = selection ?? targets.first?.id }

            List(selection: $selection) {
                ForEach(targets) { chat in
                    HStack(spacing: Metrics.s) {
                        ChatAvatar(chat: chat, model: model, size: 28)
                        Text(model.chats.title(for: chat)).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(chat.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { send(to: id) }
            }
            .overlay {
                if targets.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Forward") { if let selection { send(to: selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(Metrics.l)
        .frame(width: 380)
        .onAppear { searchFocused = true }
        .onChange(of: query) {
            // Keep a choice only while it is still listed.
            if let selection, !targets.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    private func send(to chat: String) {
        model.forward(to: chat)
    }
}
