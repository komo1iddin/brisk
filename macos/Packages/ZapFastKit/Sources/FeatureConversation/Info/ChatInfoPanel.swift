import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The inspector about the open chat: its picture and name, how to reach
/// or quiet it, and a group's members, each of whom opens their own page.
struct ChatInfoPanel: View {
    let chatID: String
    let model: AppModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            InfoPage(id: chatID, isRoot: true, model: model)
                .navigationDestination(for: String.self) { id in
                    InfoPage(id: id, isRoot: false, model: model)
                }
        }
    }
}

/// One person's or chat's page. A group member without a chat of their
/// own still has a page: name, number, and Message.
private struct InfoPage: View {
    let id: String
    let isRoot: Bool
    let model: AppModel

    @State private var renaming = false
    @State private var newName = ""
    @State private var choosingPhoto = false
    @State private var confirmingLeave = false
    @State private var editingContact = false

    var body: some View {
        let chat = model.chats.chat(id)
        ScrollView {
            VStack(spacing: Metrics.l) {
                header(chat)
                actions(chat)
                if let chat, chat.kind == .group, !chat.participants.isEmpty {
                    MemberList(members: model.chats.members(of: chat), model: model)
                }
                if let chat, chat.canLeave(ours: model.ourIDs) {
                    Button(chat.isChannel ? "Leave Channel…" : "Leave Group…", role: .destructive) {
                        confirmingLeave = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            .padding(Metrics.l)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(isRoot ? Text("Info") : Text(name(chat)))
        .alert("Rename Group", isPresented: $renaming) {
            TextField("Group name", text: $newName)
            Button("Rename") { if let chat { model.renameGroup(chat, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in the group sees the new name.")
        }
        .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let chat { model.setGroupPicture(chat, from: url) }
        }
        .confirmationDialog(
            chat?.isChannel == true ? "Leave this channel?" : "Leave this group?",
            isPresented: $confirmingLeave
        ) {
            if let chat {
                Button(chat.isChannel ? "Leave Channel" : "Leave Group", role: .destructive) {
                    model.leaveGroup(chat, archive: false)
                }
                if !chat.archived {
                    Button(chat.isChannel ? "Leave Channel and Archive" : "Leave Group and Archive", role: .destructive) {
                        model.leaveGroup(chat, archive: true)
                    }
                }
            }
        } message: {
            Text("You will not receive new messages. The local history stays on this computer.")
        }
        .sheet(isPresented: $editingContact) {
            ContactNameSheet(id: id, model: model)
        }
    }


    private func name(_ chat: ChatSummary?) -> String {
        chat.map(model.chats.title(for:)) ?? model.chats.displayName(id)
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ chat: ChatSummary?) -> some View {
        let title = name(chat)
        VStack(spacing: Metrics.xs) {
            AvatarView(
                url: model.avatars.fullURL(for: id) ?? model.avatars.url(for: id),
                seed: id,
                placeholder: placeholder(chat, title: title),
                size: 96,
                version: model.avatars.version(for: id)
            )
            .padding(.bottom, Metrics.xs)

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if let chat, chat.kind == .group {
                groupEditing(chat)
            }

            Text(kind(chat))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let phone = chat?.phone ?? phoneOf(id: id), chat?.kind != .group {
                Text(phone)
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
            }
            if let status = status(chat) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let chat, let muted = mutedLine(chat) {
                Label(muted, systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Name and photo changes, when WhatsApp lets us make them. Nothing is
    /// offered while one is on its way.
    @ViewBuilder
    private func groupEditing(_ chat: ChatSummary) -> some View {
        if model.groupSaving.contains(chat.id) {
            HStack(spacing: Metrics.xs) {
                ProgressView().controlSize(.mini)
                Text("Saving…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if chat.canEditInfo {
            Menu {
                Button("Rename Group…") {
                    newName = chat.name
                    renaming = true
                }
                Button("Choose Photo…") { choosingPhoto = true }
                if model.avatars.url(for: chat.id) != nil {
                    Button("Remove Photo", role: .destructive) { model.removeGroupPicture(chat) }
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .menuStyle(.button)
            .buttonStyle(.accessoryBar)
            .fixedSize()
        }
    }

    private func placeholder(_ chat: ChatSummary?, title: String) -> AvatarView.Placeholder {
        switch chat?.kind {
        case .group: .symbol("person.2.fill")
        case .broadcast: .symbol("megaphone.fill")
        default: .initials(title)
        }
    }

    private func kind(_ chat: ChatSummary?) -> String {
        switch chat?.kind {
        case .group:
            let count = chat?.participants.count ?? 0
            return count > 0 ? String(localized: "Group · \(count) members") : String(localized: "Group")
        case .broadcast:
            return chat?.isChannel == true ? String(localized: "Channel") : String(localized: "Broadcast list")
        default:
            return String(localized: "Contact")
        }
    }

    private func status(_ chat: ChatSummary?) -> String? {
        guard chat?.kind != .group, let presence = model.conversations.presence[id] else { return nil }
        if presence.online { return String(localized: "online") }
        return presence.lastSeen.map { DateText.lastSeen($0) }
    }

    private func mutedLine(_ chat: ChatSummary) -> String? {
        guard model.chats.isMuted(chat), let until = chat.mutedUntil else { return nil }
        if until == 0 { return String(localized: "Muted") }
        let date = DateText.date(until).formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Muted until \(date)")
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ chat: ChatSummary?) -> some View {
        let isGroup = chat?.kind == .group
        let ours = model.session.isOurs(id)
        HStack(spacing: Metrics.s) {
            if !isGroup, !ours, id != model.selectedChatID {
                ActionTile("Message", systemImage: "message") { model.startChat(with: id) }
            }
            if !isGroup, !ours, chat?.kind != .broadcast, phoneOf(id: id) != nil {
                let saved = model.chats.contacts[id]?.fullName?.isEmpty == false
                ActionTile(saved ? "Edit Name" : "Add Contact", systemImage: "person.crop.circle.badge.plus") {
                    editingContact = true
                }
            }
            if !isGroup, let phone = chat?.phone ?? phoneOf(id: id) {
                ActionTile("Copy Number", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(phone, forType: .string)
                }
            }
            if let chat {
                let muted = model.chats.isMuted(chat)
                ActionTile(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") {
                    model.setMuted(until: muted ? nil : 0, chat: chat.id)
                }
                ActionTile(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
                    model.setPinned(!chat.pinned, chat: chat.id)
                }
                ActionTile(
                    chat.archived ? "Unarchive" : "Archive",
                    systemImage: chat.archived ? "tray.and.arrow.up" : "archivebox"
                ) {
                    model.setArchived(!chat.archived, chat: chat.id)
                }
            }
        }
    }
}

/// An icon over a short label, as in Contacts and Messages.
private struct ActionTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Metrics.xs) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(height: 18)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.s)
            .background(.fill.quaternary, in: .rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect(cornerRadius: Metrics.controlRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .help(Text(title))
    }
}

/// A group's members in a card; each opens that person's page.
private struct MemberList: View {
    let members: [(id: String, name: String)]
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.xs) {
            Text("\(members.count) Members")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, Metrics.xs)

            LazyVStack(spacing: 0) {
                ForEach(members, id: \.id) { member in
                    NavigationLink(value: member.id) {
                        HStack(spacing: Metrics.s) {
                            AvatarView(
                                url: model.avatars.url(for: member.id),
                                seed: member.id,
                                placeholder: .initials(member.name.trimmingPrefix("~").description),
                                size: 24
                            )
                            Text(member.name).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Metrics.s)
                        .padding(.vertical, Metrics.xs + 1)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.session.isOurs(member.id))
                }
            }
            .padding(.vertical, Metrics.xs)
            .background(.fill.quaternary, in: .rect(cornerRadius: Metrics.cardRadius))
        }
    }
}

/// A person's name for the address book, first and last, saved through
/// WhatsApp's contact sync (and to the phone when Settings say so).
private struct ContactNameSheet: View {
    let id: String
    let model: AppModel
    @State private var first = ""
    @State private var last = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("First name", text: $first)
                TextField("Last name", text: $last)
            } header: {
                Text(phoneOf(id: id) ?? model.chats.displayName(id))
            } footer: {
                Text(model.preferences.saveContactsToPhone
                     ? "The name is also saved to your phone's contacts."
                     : "The name is saved for WhatsApp only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveContact(id, first: first, last: last)
                    dismiss()
                }
                .disabled(ContactName.compose(first: first, last: last) == nil)
            }
        }
        .onAppear(perform: prefill)
    }

    /// Starts from the saved name, split at its first name when known.
    private func prefill() {
        let contact = model.chats.contacts[id]
        guard let full = contact?.fullName, !full.isEmpty else {
            first = contact?.pushName ?? ""
            return
        }
        if let short = contact?.firstName, !short.isEmpty, full.hasPrefix(short) {
            first = short
            last = String(full.dropFirst(short.count)).trimmingCharacters(in: .whitespaces)
        } else {
            first = full
        }
    }
}
