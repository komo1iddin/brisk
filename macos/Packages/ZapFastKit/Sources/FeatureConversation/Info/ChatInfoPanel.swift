import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The open chat's info, over the chat as WhatsApp shows it: its picture
/// and name, what can be done with it, and the chat's destructive actions.
/// A group's members have a tab of their own, searchable, and each opens
/// that person's page here.
struct ChatInfoPanel: View {
    let chatID: String
    let model: AppModel
    let request: (InfoRequest) -> Void
    /// Member pages opened from here, the last one showing.
    @State private var path: [String] = []
    @State private var tab = Tab.overview
    @State private var memberQuery = ""
    @State private var memberFieldFocus = 0
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340
    static let maxHeight: CGFloat = 560

    enum Tab: Hashable {
        case overview, members
    }

    var body: some View {
        let chat = model.chats.chat(chatID)
        let hasMembers = chat.map { $0.kind == .group && !$0.participants.isEmpty } ?? false
        let showsMembers = path.isEmpty && hasMembers && tab == .members
        VStack(spacing: 0) {
            if !path.isEmpty {
                BackBar(title: backTitle) {
                    withAnimation(.zf(reduceMotion)) { _ = path.popLast() }
                }
                Divider()
            } else if let chat, hasMembers {
                tabs(chat)
            }
            ScrollView {
                Group {
                    if showsMembers, let chat {
                        MemberList(members: members(of: chat), model: model) { open($0) }
                            .padding([.horizontal, .bottom], Metrics.l)
                            .padding(.top, Metrics.s)
                    } else {
                        InfoPage(id: path.last ?? chatID, isRoot: path.isEmpty, model: model, request: request)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), Self.maxHeight))
            .id(path.last.map { "person-\($0)" } ?? "\(tab)")
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
        }
        .frame(width: Self.width)
        // A click on a group member's name opens on their page.
        .onChange(of: model.infoPerson, initial: true) { _, person in
            if let person { path = [person] }
        }
    }

    /// Overview and Members, and the members' search while that shows.
    @ViewBuilder
    private func tabs(_ chat: ChatSummary) -> some View {
        VStack(spacing: Metrics.s) {
            Picker("Show", selection: $tab.animation(.zf(reduceMotion))) {
                Text("Overview").tag(Tab.overview)
                Text("Members · \(chat.participants.count)").tag(Tab.members)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .members {
                SearchField(
                    text: $memberQuery,
                    prompt: String(localized: "Search members"),
                    focusRequest: memberFieldFocus,
                    onEscape: { model.closeInfo() }
                )
            }
        }
        .padding(.horizontal, Metrics.l)
        .padding(.top, Metrics.m)
        .padding(.bottom, tab == .members ? 0 : Metrics.xs)
        .onChange(of: tab) { if tab == .members { memberFieldFocus += 1 } }
    }

    /// The group's members, those matching the search by name or number.
    private func members(of chat: ChatSummary) -> [(id: String, name: String)] {
        let all = model.chats.members(of: chat)
        let query = memberQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let digits = query.filter(\.isNumber)
        return all.filter { member in
            member.name.localizedStandardContains(query)
                || (!digits.isEmpty && (phoneOf(id: member.id)?.filter(\.isNumber).contains(digits) ?? false))
        }
    }

    private func open(_ member: String) {
        withAnimation(.zf(reduceMotion)) { path.append(member) }
    }

    /// The page the back button returns to.
    private var backTitle: String {
        guard path.count > 1 else {
            if tab == .members { return String(localized: "Members") }
            return model.chats.chat(chatID).map(model.chats.title(for:)) ?? model.chats.displayName(chatID)
        }
        let parent = path[path.count - 2]
        return model.chats.chat(parent).map(model.chats.title(for:)) ?? model.chats.displayName(parent)
    }
}

private struct BackBar: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Label(title, systemImage: "chevron.backward")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help("Back")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
    }
}

/// One person's or chat's page. A group member without a chat of their
/// own still has a page: name, number, and Message.
private struct InfoPage: View {
    let id: String
    let isRoot: Bool
    let model: AppModel
    let request: (InfoRequest) -> Void

    var body: some View {
        let chat = model.chats.chat(id)
        VStack(spacing: Metrics.l) {
            header(chat)
            actions(chat)
            details(chat)
            if isRoot, let chat {
                destructive(chat)
            }
        }
        .padding(Metrics.l)
        .frame(maxWidth: .infinity)
    }

    private func name(_ chat: ChatSummary?) -> String {
        chat.map(model.chats.title(for:)) ?? model.chats.displayName(id)
    }

    private func phone(_ chat: ChatSummary?) -> String? {
        guard chat?.kind != .group else { return nil }
        return chat?.phone ?? phoneOf(id: id)
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

            if let status = status(chat) {
                Text(status)
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
                Button("Rename Group…") { request(.rename(chat)) }
                Button("Choose Photo…") { request(.choosePhoto(chat)) }
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
        guard chat?.kind != .group, let presence = model.conversations.presence(of: id) else { return nil }
        if presence.online { return String(localized: "online") }
        return presence.lastSeen.map { DateText.lastSeen($0) }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ chat: ChatSummary?) -> some View {
        let isGroup = chat?.kind == .group
        let ours = model.session.isOurs(id)
        HStack(spacing: Metrics.s) {
            if !isRoot, !isGroup, !ours {
                ActionTile("Message", systemImage: "message") {
                    model.closeInfo()
                    model.startChat(with: id)
                }
            }
            if isRoot, let chat {
                ActionTile("Search", systemImage: "magnifyingglass") { model.openChatSearch(in: chat.id) }
            }
            if !isGroup, !ours, chat?.kind != .broadcast, phoneOf(id: id) != nil {
                let saved = model.chats.contacts[id]?.fullName?.isEmpty == false
                ActionTile(saved ? "Edit Name" : "Add Contact", systemImage: "person.crop.circle.badge.plus") {
                    request(.editContact(id))
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

    // MARK: Details

    @ViewBuilder
    private func details(_ chat: ChatSummary?) -> some View {
        let phone = phone(chat)
        let muted = chat.flatMap(mutedLine)
        if phone != nil || muted != nil {
            VStack(spacing: 0) {
                if let phone {
                    DetailRow(title: "Phone number", value: phone) {
                        Button("Copy Number", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(phone, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy the number")
                    }
                }
                if phone != nil, muted != nil { Divider().padding(.leading, Metrics.m) }
                if let muted {
                    DetailRow(title: "Notifications", value: muted) { EmptyView() }
                }
            }
            .background(.fill.quaternary, in: .rect(cornerRadius: Metrics.cardRadius))
        }
    }

    private func mutedLine(_ chat: ChatSummary) -> String? {
        guard model.chats.isMuted(chat), let until = chat.mutedUntil else { return nil }
        if until == 0 { return String(localized: "Muted") }
        let date = DateText.date(until).formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Muted until \(date)")
    }

    // MARK: Leaving, clearing, deleting

    /// As at the foot of WhatsApp's info: each asks first, in the window.
    @ViewBuilder
    private func destructive(_ chat: ChatSummary) -> some View {
        let leaves = chat.canLeave(ours: model.ourIDs)
        VStack(spacing: 0) {
            if leaves {
                DestructiveRow(
                    title: chat.isChannel ? "Leave Channel…" : "Leave Group…",
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) { request(.leave(chat)) }
                Divider().padding(.leading, Metrics.m)
            }
            DestructiveRow(title: "Clear Chat…", systemImage: "eraser") {
                model.closeInfo()
                model.confirmClear(chat.id)
            }
            .disabled(!model.canClearOrDeleteChats)
            Divider().padding(.leading, Metrics.m)
            DestructiveRow(title: "Delete Chat…", systemImage: "trash") {
                model.closeInfo()
                model.confirmDelete(chat.id)
            }
            .disabled(!model.canClearOrDeleteChats)
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: Metrics.cardRadius))
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

/// A caption over a value in a card, with an optional accessory.
private struct DetailRow<Accessory: View>: View {
    let title: LocalizedStringKey
    let value: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Metrics.s) {
            VStack(alignment: .leading, spacing: Metrics.xxs) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, Metrics.m)
        .padding(.vertical, Metrics.s)
    }
}

/// A red action in a card, as at the foot of WhatsApp's info.
private struct DestructiveRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.m)
                .padding(.vertical, Metrics.s)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
    }
}

/// A group's members in a card; each opens that person's page.
private struct MemberList: View {
    let members: [(id: String, name: String)]
    let model: AppModel
    let open: (String) -> Void

    var body: some View {
        if members.isEmpty {
            Text("No members match")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.xl)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(members, id: \.id) { member in
                    Button {
                        open(member.id)
                    } label: {
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
