import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The search over the top of an open chat, in one glass bar: the field
/// with its filters as tokens, the count, the arrows that walk the matches
/// in the timeline, and the buttons that add a sender, a kind and a date.
/// Under it, the matches as a list, open by itself with each new search
/// until one is picked, or the people to pick a sender from. Those are on a
/// solid panel: glass over a list is harder to read and blurs the chat
/// behind it on every frame.
///
/// The arrows go the way the chat does: ↑ to older matches, higher up the
/// chat. In the list, newest first, ↓ goes to older ones, down the list.
struct ChatSearchBar: View {
    let chatID: String
    let model: AppModel
    @State private var focusRequest = 0
    @State private var choosingDay = false
    /// The kinds of message show as chips under the bar.
    @State private var choosingKind = false
    /// The person the arrow keys reached among those offered.
    @State private var person = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 40

    var body: some View {
        if let search = model.search.chat, search.chat == chatID {
            VStack(spacing: Metrics.s) {
                bar(search)
                if choosingKind {
                    KindChips(kind: search.kind) { model.setChatSearchKind($0) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if search.pickingSender {
                    PeoplePicker(people: people(search), selected: person, model: model) { pick($0) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if search.listShown, search.isAsking, !(search.pending && search.hits.isEmpty) {
                    HitList(search: search, model: model)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, Metrics.m)
            .padding(.top, Metrics.s)
            .padding(.bottom, Metrics.l)
            .animation(.zf(reduceMotion), value: search.listShown)
            .animation(.zf(reduceMotion), value: search.pickingSender)
            .animation(.zf(reduceMotion), value: choosingKind)
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

            if canPickSender {
                BarButton(symbol: "person", help: searchText("search.sender"), active: search.pickingSender || search.sender != nil) {
                    if search.pickingSender { model.cancelPickingChatSearchSender() } else { model.beginPickingChatSearchSender() }
                }
            }
            BarButton(
                symbol: search.kind == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                help: searchText("search.kind"),
                active: choosingKind || search.kind != nil
            ) {
                choosingKind.toggle()
                if choosingKind { model.cancelPickingChatSearchSender() }
            }
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
        if let kind = search.kind, !choosingKind {
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

    /// Escape undoes one thing at a time: the picker, the kinds, the list,
    /// the words, and then the search itself.
    private func escape(_ search: ChatSearch) {
        if search.pickingSender {
            model.cancelPickingChatSearchSender()
        } else if choosingKind {
            choosingKind = false
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

/// The kinds of message as a row of chips under the bar, as Telegram lays
/// out a chat's shared media: one click keeps the search to a kind, and
/// All lifts that. Solid, as the list is, so their words read over the chat.
private struct KindChips: View {
    let kind: SearchKindInfo?
    let choose: (SearchKindInfo?) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.xs) {
                KindChip(title: searchText("search.kind.any"), symbol: "tray.full", selected: kind == nil) {
                    choose(nil)
                }
                ForEach(SearchKindInfo.all, id: \.self) { item in
                    KindChip(title: item.title, symbol: item.symbol, selected: kind == item) {
                        choose(item)
                    }
                }
            }
            .padding(.vertical, Metrics.xxs)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }
}

private struct KindChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, Metrics.m)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(.tint)
                    } else {
                        Capsule().fill(Color(nsColor: .windowBackgroundColor))
                            .overlay(Capsule().fill(.primary.opacity(hovering ? 0.06 : 0)))
                            .overlay(Capsule().strokeBorder(.separator))
                    }
                }
                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    }
                }
                .buttonStyle(SearchRowStyle(selected: index == selected))
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
                }
                .buttonStyle(SearchRowStyle(selected: index == search.current))
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

/// A solid panel under the bar, as tall as its rows up to a limit, that
/// scrolls past it, keeping the row the keys reached in view.
private struct DropdownList<Content: View>: View {
    let selected: Int
    @ViewBuilder let content: Content
    /// The rows' height, measured: a lazy stack's own guess left room under
    /// a short list.
    @State private var height: CGFloat = 0

    static var tallest: CGFloat { 360 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    content
                }
                .padding(Metrics.xs)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .slimScrollBar()
            .frame(height: height > 0 ? min(height, Self.tallest) : nil)
            .frame(maxHeight: Self.tallest)
            .onChange(of: selected) { _, index in
                guard index >= 0 else { return }
                proxy.scrollTo(index)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
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
        case .voice: "mic"
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
