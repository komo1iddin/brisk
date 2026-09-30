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
    @State private var choosingDay = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.xs) {
                SearchField(
                    text: Binding(get: { search.query }, set: { model.setChatSearchQuery($0) }),
                    prompt: String(localized: "Search this chat"),
                    focusRequest: focusRequest,
                    onSubmit: { model.revealChatSearchHit(search.selected ?? 0) },
                    onMove: { down in model.stepChatSearch(older: down) },
                    onEscape: {
                        // Escape closes the calendar first, as upstream's does.
                        if choosingDay { choosingDay = false } else { model.closeChatSearch() }
                    }
                )
                Button {
                    choosingDay.toggle()
                } label: {
                    Label("Search by Date", systemImage: search.day == nil ? "calendar" : "calendar.badge.checkmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15))
                        .foregroundStyle(search.day == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Search by date")
                .popover(isPresented: $choosingDay, arrowEdge: .bottom) {
                    DayChooser(day: search.day) { day in
                        choosingDay = false
                        model.setChatSearchDay(day)
                    }
                }
            }
            .padding(.horizontal, Metrics.m)
            .padding(.vertical, Metrics.s)

            if let day = search.day {
                HStack(spacing: Metrics.xs) {
                    Image(systemName: "calendar").foregroundStyle(.tint)
                    Text(day, format: .dateTime.weekday(.wide).day().month(.wide).year())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.setChatSearchDay(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Search every day")
                    .accessibilityLabel("Search every day")
                }
                .font(.callout)
                .padding(.horizontal, Metrics.s)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.12), in: Capsule())
                .padding(.horizontal, Metrics.m)
                .padding(.bottom, Metrics.s)
                .transition(.opacity)
            }

            Divider()

            results
                .frame(maxHeight: .infinity)
        }
        .onChange(of: model.chatSearchFocusRequests, initial: true) { focusRequest += 1 }
    }

    @ViewBuilder private var results: some View {
        let query = search.trimmedQuery
        if !search.isAsking {
            ContentUnavailableView(
                "Search this chat",
                systemImage: "magnifyingglass",
                description: Text("Find messages by the words in them, or by the day they were sent.")
            )
        } else if search.hits.isEmpty {
            if search.pending {
                ProgressView().controlSize(.small)
            } else if query.isEmpty {
                ContentUnavailableView(
                    "No messages that day",
                    systemImage: "calendar",
                    description: Text("Pick another day, or search every day.")
                )
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

/// The calendar for searching one day: today and earlier, the chosen day
/// marked; choosing it again searches every day, as upstream's does.
private struct DayChooser: View {
    let day: Date?
    let choose: (Date?) -> Void
    @State private var picked: Date

    init(day: Date?, choose: @escaping (Date?) -> Void) {
        self.day = day
        self.choose = choose
        _picked = State(initialValue: day ?? .now)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.s) {
            DatePicker("Day", selection: $picked, in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if day != nil {
                    Button("Every Day") { choose(nil) }
                }
                Spacer()
                Button("Search This Day") { choose(picked) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.m)
        .frame(width: 260)
    }
}
