import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// "Send to…": what came from the Share menu, and the chat it goes to.
/// Choosing one opens it with the files above the field and the text in
/// it, so a caption can be added and nothing leaves until Send.
struct ShareSheet: View {
    let request: ShareRequest
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: String?

    var body: some View {
        let chats = model.chats.visibleChats(filter: .all, query: query, archived: false)
            + (query.isEmpty ? model.chats.visibleChats(filter: .channels, query: "", archived: false).filter(\.admin) : [])
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Send to…").font(.headline)
            Label(summary, systemImage: request.files.isEmpty ? "text.alignleft" : "paperclip")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            List(chats, selection: $chosen) { chat in
                HStack(spacing: Metrics.s) {
                    ChatAvatar(chat: chat, model: model, size: 28)
                    Text(model.chats.title(for: chat)).lineLimit(1)
                }
                .tag(chat.id)
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { send(to: id) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.shareRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { if let chosen { send(to: chosen) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(Metrics.l)
        .frame(width: 420, height: 480)
    }

    private func send(to chat: String) {
        model.deliverShare(to: chat)
    }

    private var summary: String {
        var parts: [String] = []
        if !request.files.isEmpty {
            parts.append(request.files.count == 1
                ? request.files[0].lastPathComponent
                : String(localized: "\(request.files.count) files"))
        }
        if !request.text.isEmpty {
            parts.append(request.text.replacing("\n", with: " "))
        }
        return parts.joined(separator: " · ")
    }
}
