import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The search over the top of an open chat, in one glass bar: the field
/// with its filters as tokens, the count, the arrows that walk the matches
/// in the timeline, and the buttons that add a sender, a kind and a date.
/// Under it, when asked for, the matches as a list or the people to pick a
/// sender from.
///
/// The arrows go the way the chat does: ↑ to older matches, higher up the
/// chat. In the list, newest first, ↓ goes to older ones, down the list.
struct ChatSearchBar: View {
    let chatID: String
    let model: AppModel
    @State private var focusRequest = 0
    @State private var choosingDay = false
    /// The person the arrow keys reached among those offered.
    @State private var person = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 40

    var body: some View {
        if let search = model.search.chat, search.chat == chatID {
            VStack(spacing: Metrics.s) {
                bar(search)
                if search.pickingSender {
                    PeoplePicker(people: people(search), selected: person, model: model) { pick($0) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if search.listShown, search.isAsking {
                    HitList(search: search, model: model)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, Metrics.m)
            .padding(.top, Metrics.s)
            .padding(.bottom, Metrics.l)
            .animation(.zf(reduceMotion), value: search.listShown)
            .animation(.zf(reduceMotion), value: search.pickingSender)
            .onChange(of: model.chatSearchFocusRequests, initial: true) { focusRequest += 1 }
            .onChange(of: search.senderText) { person = 0 }
        }
    }

    // MARK: The bar

    private func bar(_ search: ChatSearch) -> some View {
        HStack(spacing: Metrics.xxs) {
            HStack(spacing: Metrics.xs + 2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                tokens(search)
                BareSearchField(
                    text: Binding(get: { search.fieldText }, set: { model.setChatSearchQuery($0) }),
                    prompt: search.pickingSender ? searchText("search.prompt.people") : searchText("search.prompt"),
                    focusRequest: focusRequest,
                    onSubmit: { shift in submit(search, shift: shift) },
                    onMove: { down in move(search, down: down) },
                    onEscape: { escape(search) },
                    onDeleteAtStart: { deleteAtStart(search) }
                )
                .frame(minWidth: 60)
                if !search.fieldText.isEmpty {
                    Button {
                        model.setChatSearchQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(searchText("search.clear"))
                    .accessibilityLabel(searchText("search.clear"))
                }
            }
            .padding(.leading, Metrics.m)
            .padding(.trailing, Metrics.xs)
            .frame(maxWidth: .infinity)

            Counter(search: search)
                .padding(.horizontal, Metrics.xs)

            BarButton(symbol: "chevron.up", help: searchText("search.older")) {
                model.stepChatSearch(older: true)
            }
            .disabled(search.ids.isEmpty || search.current == search.ids.count - 1)
            BarButton(symbol: "chevron.down", help: searchText("search.newer")) {
                model.stepChatSearch(older: false)
            }
            .disabled(search.ids.isEmpty || (search.current ?? 0) == 0)

            Divider().frame(height: 18).padding(.horizontal, Metrics.xxs)

            BarButton(
                symbol: "list.bullet",
                help: search.listShown ? searchText("search.list.hide") : searchText("search.list.show"),
                active: search.listShown
            ) {
                model.setChatSearchList(!search.listShown)
            }
            .disabled(!search.isAsking)
            if canPickSender {
                BarButton(symbol: "person", help: searchText("search.sender"), active: search.pickingSender || search.sender != nil) {
                    if search.pickingSender { model.cancelPickingChatSearchSender() } else { model.beginPickingChatSearchSender() }
                }
            }
            KindMenu(kind: search.kind) { model.setChatSearchKind($0) }
            BarButton(symbol: "calendar", help: searchText("search.calendar"), active: search.day != nil) {
                choosingDay.toggle()
            }
            .popover(isPresented: $choosingDay, arrowEdge: .bottom) {
                SearchCalendar(search: search, model: model) { choosingDay = false }
            }
            BarButton(symbol: "xmark", help: searchText("search.close")) {
                model.closeChatSearch()
            }
            .padding(.trailing, Metrics.xs)
        }
        .frame(height: Self.height)
        .searchSurface(Capsule())
    }

    /// The filters, as tokens before the words; a click takes one off.
    @ViewBuilder private func tokens(_ search: ChatSearch) -> some View {
        if let sender = search.sender {
            Token(help: searchText("search.filter.remove"), remove: { model.setChatSearchSender(nil) }) {
                let shown = name(of: sender)
                SenderAvatar(sender: sender, name: shown, model: model, size: 16)
                Text(shown)
            }
        }
        if let kind = search.kind {
            Token(help: searchText("search.filter.remove"), remove: { model.setChatSearchKind(nil) }) {
                Image(systemName: kind.symbol)
                Text(kind.title)
            }
        }
        if let day = search.day {
            Token(help: searchText("search.filter.remove"), remove: { model.setChatSearchDay(nil) }) {
                Image(systemName: "calendar")
                Text(day, format: .dateTime.day().month(.abbreviated).year())
            }
        }
    }

    // MARK: Keys

    private func move(_ search: ChatSearch, down: Bool) {
        if search.pickingSender {
            let count = people(search).count
            person = max(0, min(person + (down ? 1 : -1), count - 1))
        } else if search.listShown {
            model.stepChatSearch(older: down)
        } else {
            model.stepChatSearch(older: !down)
        }
    }

    private func submit(_ search: ChatSearch, shift: Bool) {
        if search.pickingSender {
            let offered = people(search)
            if offered.indices.contains(person) { pick(offered[person]) }
        } else if search.listShown {
            if search.current == nil { model.stepChatSearch(older: true) }
            model.setChatSearchList(false)
        } else {
            model.stepChatSearch(older: !shift)
        }
    }

    /// Escape undoes one thing at a time: the picker, the list, the words,
    /// and then the search itself.
    private func escape(_ search: ChatSearch) {
        if search.pickingSender {
            model.cancelPickingChatSearchSender()
        } else if search.listShown {
            model.setChatSearchList(false)
        } else if !search.query.isEmpty {
            model.setChatSearchQuery("")
        } else {
            model.closeChatSearch()
        }
    }

    /// Delete before the first word takes the last filter off.
    private func deleteAtStart(_ search: ChatSearch) {
        if search.pickingSender {
            if search.senderText.isEmpty { model.cancelPickingChatSearchSender() }
        } else if search.day != nil {
            model.setChatSearchDay(nil)
        } else if search.kind != nil {
            model.setChatSearchKind(nil)
        } else if search.sender != nil {
            model.setChatSearchSender(nil)
        }
    }

    // MARK: People

    private var canPickSender: Bool {
        guard let chat = model.chats.chat(chatID) else { return false }
        return !chat.isChannel && chat.kind != .broadcast
    }

    /// Who wrote in this chat: a group's members, or the other person and
    /// us, and anyone else whose messages are loaded (a group whose members
    /// are not known yet, someone who has left), narrowed by the name typed,
    /// folded as the search folds words.
    private func people(_ search: ChatSearch) -> [SearchPerson] {
        guard let chat = model.chats.chat(chatID) else { return [] }
        let session = model.session
        var everyone: [SearchPerson] = switch chat.kind {
        case .group:
            model.chats.members(of: chat).map { member in
                session.isOurs(member.id)
                    ? SearchPerson(id: member.id, name: searchText("search.you"), sender: .me)
                    : SearchPerson(id: member.id, name: member.name, sender: .person(member.id))
            }
        case .direct, .broadcast:
            [SearchPerson(id: chat.id, name: model.chats.title(for: chat), sender: .person(chat.id))]
                + (session.account.map { [SearchPerson(id: $0.id, name: searchText("search.you"), sender: .me)] } ?? [])
        }
        if chat.kind == .group {
            var known = Set(everyone.map(\.id))
            for message in model.conversations.conversation(chatID).messages.reversed()
            where !message.fromMe && known.insert(message.sender).inserted {
                let name = model.chats.displayName(message.sender, hint: message.senderName)
                everyone.append(SearchPerson(id: message.sender, name: name, sender: .person(message.sender)))
            }
        }
        let typed = search.senderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return everyone }
        return everyone.filter { searchMatches(text: $0.name, query: typed) || searchMatches(text: $0.id, query: typed) }
    }

    private func pick(_ person: SearchPerson) {
        model.setChatSearchSender(person.sender)
    }

    private func name(of sender: ChatSearchSender) -> String {
        switch sender {
        case .me: searchText("search.you")
        case .person(let id):
            // A loaded message carries the name its sender gave, which a
            // number alone does not.
            model.chats.displayName(
                id,
                hint: model.conversations.conversation(chatID).messages.last { $0.sender == id }?.senderName
            )
        }
    }
}

/// Someone a search can be kept to.
struct SearchPerson: Identifiable, Equatable {
    let id: String
    let name: String
    let sender: ChatSearchSender
}

// MARK: - Parts of the bar

/// "3 of 27", the number found before a match is shown, or that none were.
private struct Counter: View {
    let search: ChatSearch

    var body: some View {
        Group {
            if !search.isAsking {
                EmptyView()
            } else if search.pending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(searchText("search.searching"))
            } else if search.ids.isEmpty {
                Text(searchText("search.none"))
                    .foregroundStyle(.secondary)
            } else if let current = search.current {
                Text(searchText("search.counter \(current + 1) \(search.ids.count)"))
            } else if search.truncated {
                Text(searchText("search.count.more \(search.ids.count)"))
            } else {
                Text(searchText("search.count \(search.ids.count)"))
            }
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .contentTransition(.numericText())
    }
}

/// One of the bar's round buttons.
private struct BarButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(isEnabled ? .primary : .tertiary))
                .frame(width: 30, height: 30)
                .background {
                    if active { Circle().fill(.tint.opacity(0.14)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The kinds of message, as a menu; the chosen one is ticked.
private struct KindMenu: View {
    let kind: SearchKindInfo?
    let choose: (SearchKindInfo?) -> Void

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { kind }, set: { choose($0) })) {
                Label(searchText("search.kind.any"), systemImage: "tray.full").tag(SearchKindInfo?.none)
                Divider()
                ForEach(SearchKindInfo.all, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(Optional(kind))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: kind == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(kind == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .fixedSize()
        .help(searchText("search.kind"))
        .accessibilityLabel(searchText("search.kind"))
    }
}

/// A filter in the field: what it keeps to, and a cross that takes it off.
private struct Token<Content: View>: View {
    let help: String
    let remove: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: Metrics.xs) {
                content
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(hovering ? 1 : 0.6)
            }
            .font(.callout)
            .foregroundStyle(.tint)
            .padding(.horizontal, Metrics.s)
            .padding(.vertical, 3)
            .background(.tint.opacity(hovering ? 0.22 : 0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .layoutPriority(-1)
    }
}

/// A sender's picture: ours, or the person's.
struct SenderAvatar: View {
    let sender: ChatSearchSender
    /// The name shown beside it, which knows more than the id alone.
    var name: String?
    let model: AppModel
    let size: CGFloat

    var body: some View {
        let id: String = switch sender {
        case .me: model.session.account?.id ?? ""
        case .person(let id): id
        }
        let known: String = switch sender {
        case .me: model.session.account?.name ?? searchText("search.you")
        case .person(let id): model.chats.personName(id, hint: nil)
        }
        let name = name ?? known
        AvatarView(
            url: model.avatars.url(for: id), seed: id,
            placeholder: .initials(name.trimmingPrefix("~").description), size: size,
            version: model.avatars.version(for: id)
        )
    }
}

// MARK: - Under the bar

/// The people to keep the search to, narrowed by the name typed.
private struct PeoplePicker: View {
    let people: [SearchPerson]
    let selected: Int
    let model: AppModel
    let pick: (SearchPerson) -> Void

    var body: some View {
        DropdownList(selected: selected) {
            if people.isEmpty {
                Text(searchText("search.people.none"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(Metrics.m)
            }
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                Button { pick(person) } label: {
                    HStack(spacing: Metrics.m) {
                        SenderAvatar(sender: person.sender, name: person.name, model: model, size: 30)
                        Text(person.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metrics.m)
                    .padding(.vertical, Metrics.xs + 2)
                    .background(index == selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .id(index)
            }
        }
    }
}

/// The matches, newest first, each with who wrote it, when, and the words
/// found in it. Picking one shows it in the chat and closes the list.
private struct HitList: View {
    let search: ChatSearch
    let model: AppModel

    var body: some View {
        DropdownList(selected: search.current ?? -1) {
            if search.hits.isEmpty, !search.pending {
                Text(searchText("search.none"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(Metrics.m)
            }
            ForEach(Array(search.hits.enumerated()), id: \.element.id) { index, hit in
                Button {
                    model.revealChatSearchHit(index)
                    model.setChatSearchList(false)
                } label: {
                    HitRow(message: hit, query: search.trimmedQuery, model: model)
                        .padding(.horizontal, Metrics.m)
                        .padding(.vertical, Metrics.xs + 2)
                        .background(index == search.current ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .id(index)
            }
            if search.truncated {
                note(searchText("search.list.truncated"))
            } else if search.hits.count < search.ids.count {
                note(searchText("search.list.more \(search.hits.count) \(search.ids.count)"))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.m)
    }
}

/// One match: who wrote it and when, and the text around the words found.
private struct HitRow: View {
    let message: MessageRecord
    let query: String
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.m) {
            SenderAvatar(sender: message.fromMe ? .me : .person(message.sender), model: model, size: 30)
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
        }
        .accessibilityElement(children: .combine)
    }

    private var sender: String {
        message.fromMe ? searchText("search.you") : model.chats.displayName(message.sender, hint: message.senderName)
    }
}

/// A glass panel under the bar that scrolls, keeping the row the keys
/// reached in view.
private struct DropdownList<Content: View>: View {
    let selected: Int
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.vertical, Metrics.xs)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { _, index in
                guard index >= 0 else { return }
                proxy.scrollTo(index)
            }
        }
        .searchSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Kinds

extension SearchKindInfo {
    static let all: [SearchKindInfo] = [.photos, .videos, .gifs, .files, .links, .voice, .music]

    var title: String {
        switch self {
        case .photos: searchText("search.kind.photos")
        case .videos: searchText("search.kind.videos")
        case .gifs: searchText("search.kind.gifs")
        case .files: searchText("search.kind.files")
        case .links: searchText("search.kind.links")
        case .voice: searchText("search.kind.voice")
        case .music: searchText("search.kind.music")
        }
    }

    var symbol: String {
        switch self {
        case .photos: "photo"
        case .videos: "video"
        case .gifs: "play.square.stack"
        case .files: "doc"
        case .links: "link"
        case .voice: "waveform"
        case .music: "music.note"
        }
    }
}

// MARK: - Surface

private extension View {
    /// Glass on macOS 26, as the composer floats; a thick material before.
    @ViewBuilder
    func searchSurface<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }
}
