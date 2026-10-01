import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Picks the chats to forward to, as the phone's "Send to": our own chat
/// first, then the chats that can receive, most recent first. Click rows
/// to tick them, add a message if wanted, and Forward; a double-click
/// forwards at once. Return in the search field ticks the first match.
struct ForwardSheet: View {
    let request: ForwardRequest
    let model: AppModel

    @State private var query = ""
    /// Ticked chats, in the order they were ticked.
    @State private var picked: [String] = []
    @State private var note = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let me = model.forwardSelfTarget(query: query)
        let targets = model.chats.forwardTargets(query: query).filter { !model.session.isOurs($0.id) }
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text(request.messages.count == 1 ? "Forward Message" : "Forward \(request.messages.count) Messages")
                .font(.headline)

            TextField("Search chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { submitSearch(first: me ?? targets.first?.id) }

            List {
                if let me {
                    TargetRow(
                        id: me, title: model.chats.selfTitle, subtitle: String(localized: "Message yourself"),
                        chat: model.chats.chat(me), picked: picked.contains(me), model: model,
                        toggle: { toggle(me) }, forward: { forwardNow(me) }
                    )
                }
                if !targets.isEmpty {
                    Section("Recent Chats") {
                        ForEach(targets) { chat in
                            TargetRow(
                                id: chat.id, title: model.chats.title(for: chat), subtitle: subtitle(for: chat),
                                chat: chat, picked: picked.contains(chat.id), model: model,
                                toggle: { toggle(chat.id) }, forward: { forwardNow(chat.id) }
                            )
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .overlay {
                if targets.isEmpty, me == nil { ContentUnavailableView.search(text: query) }
            }
            .frame(minHeight: 340)

            TextField("Add a message…", text: $note)
                .textFieldStyle(.roundedBorder)
                .onSubmit(forward)
                .disabled(picked.isEmpty)

            HStack(spacing: Metrics.s) {
                Text(pickedNames)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(pickedNames)
                Spacer(minLength: Metrics.s)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Forward", action: forward)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
        .padding(Metrics.l)
        .frame(width: 420)
        .onAppear { searchFocused = true }
    }

    /// Under a group its members; under a person their number, when the
    /// name shown is not already it.
    private func subtitle(for chat: ChatSummary) -> String? {
        switch chat.kind {
        case .group:
            let members = model.chats.participantNames(chat)
            return members.isEmpty || members == model.chats.title(for: chat) ? nil : members
        case .direct:
            guard let phone = PhoneFormat.display(id: chat.id) ?? chat.phone, phone != model.chats.title(for: chat) else { return nil }
            return phone
        case .broadcast:
            return nil
        }
    }

    private var pickedNames: String {
        picked.map(model.forwardTargetName).joined(separator: ", ")
    }

    private func toggle(_ id: String) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else {
            picked.append(id)
        }
    }

    /// Return in the search field ticks the first match and clears the
    /// search for the next name; with nothing typed it forwards.
    private func submitSearch(first: String?) {
        if query.isEmpty {
            forward()
        } else if let first {
            if !picked.contains(first) { picked.append(first) }
            query = ""
        }
    }

    /// A double-click: this chat, with any already ticked.
    private func forwardNow(_ id: String) {
        if !picked.contains(id) { picked.append(id) }
        forward()
    }

    private func forward() {
        guard !picked.isEmpty else { return }
        model.forward(to: picked, note: note)
    }
}

/// One chat to forward to: its photo, name, a line under it, and a tick.
private struct TargetRow: View {
    let id: String
    let title: String
    let subtitle: String?
    let chat: ChatSummary?
    let picked: Bool
    let model: AppModel
    let toggle: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: Metrics.s) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Metrics.s)
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .simultaneousGesture(TapGesture(count: 2).onEnded(forward))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityAction(named: Text("Forward")) { forward() }
    }

    @ViewBuilder private var avatar: some View {
        if let chat {
            ChatAvatar(chat: chat, model: model, size: 32)
        } else {
            AvatarView(
                url: model.avatars.url(for: id),
                seed: id,
                placeholder: .initials(title),
                size: 32,
                version: model.avatars.version(for: id)
            )
        }
    }
}
