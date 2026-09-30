import SwiftUI
import ZapFastBridge
import ZapFastDesign

/// The reaction popover: the quick reactions in a row, and + for every
/// emoji, searchable, with the most used first (upstream's reaction
/// picker). Choosing ours again takes it back.
struct ReactionPicker: View {
    let quick: [String]
    let mine: String?
    let frequent: [String]
    let choose: (String) -> Void

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if expanded {
            EmojiCatalog(frequent: frequent, mine: mine, choose: pick)
        } else {
            HStack(spacing: Metrics.xxs) {
                ForEach(quick, id: \.self) { emoji in
                    EmojiButton(emoji: emoji, size: 24, marked: emoji == mine) { pick(emoji) }
                        .help(emoji == mine ? Text("Remove \(emoji)") : Text(verbatim: emoji))
                }
                Button {
                    withAnimation(.zf(reduceMotion)) { expanded = true }
                } label: {
                    Label("More Reactions", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(.quaternary, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("More reactions")
            }
            .padding(Metrics.s)
        }
    }

    private func pick(_ emoji: String) {
        choose(emoji == mine ? "" : emoji)
    }
}

/// Every emoji by category, with a search field and a row of category
/// tabs that scroll to each.
struct EmojiCatalog: View {
    let frequent: [String]
    let mine: String?
    let choose: (String) -> Void

    @State private var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searching: Bool

    private static let groups = emojiGroups()
    private static let columns = Array(repeating: GridItem(.fixed(34), spacing: 2), count: 9)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
            }
            .padding(.horizontal, Metrics.s)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: Metrics.controlRadius))
            .padding(Metrics.s)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            if !frequent.isEmpty {
                                section("Frequently Used", frequent, id: "Frequently Used")
                            }
                            ForEach(Self.groups, id: \.name) { group in
                                section(LocalizedStringKey(group.name), group.emoji, id: group.name)
                            }
                        } else {
                            let found = emojiSearch(query: query)
                            if found.isEmpty {
                                Text("Nothing matches")
                                    .foregroundStyle(.secondary)
                                    .gridCellColumns(9)
                                    .padding(Metrics.l)
                            } else {
                                grid(found)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.s)
                    .padding(.bottom, Metrics.s)
                }
                .frame(height: 300)

                Divider()
                HStack(spacing: 0) {
                    tab("🕒", "Frequently Used", id: "Frequently Used", proxy: proxy)
                        .disabled(frequent.isEmpty)
                    ForEach(Self.groups, id: \.name) { group in
                        tab(group.symbol, LocalizedStringKey(group.name), id: group.name, proxy: proxy)
                    }
                }
                .padding(.horizontal, Metrics.s)
                .padding(.vertical, Metrics.xs)
            }
        }
        .frame(width: 9 * 36 + Metrics.s * 2)
        .onAppear { searching = true }
    }

    private func section(_ title: LocalizedStringKey, _ emoji: [String], id: String) -> some View {
        Section {
            grid(emoji)
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Metrics.xs)
                .background(.background.opacity(0.95))
        }
        .id(id)
    }

    private func grid(_ emoji: [String]) -> some View {
        ForEach(emoji, id: \.self) { emoji in
            EmojiButton(emoji: emoji, size: 24, marked: emoji == mine) { choose(emoji) }
        }
    }

    private func tab(_ symbol: String, _ title: LocalizedStringKey, id: String, proxy: ScrollViewProxy) -> some View {
        Button {
            query = ""
            withAnimation(.zf(reduceMotion)) { proxy.scrollTo(id, anchor: .top) }
        } label: {
            Text(symbol)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct EmojiButton: View {
    let emoji: String
    let size: CGFloat
    let marked: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: size))
                .frame(width: 34, height: 34)
                .background {
                    if marked {
                        Circle().fill(.tint.opacity(0.25))
                    } else if hovered {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    }
                }
                .scaleEffect(hovered && !reduceMotion ? 1.12 : 1)
                .animation(.zf(reduceMotion, duration: 0.12), value: hovered)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(verbatim: emoji))
    }
}
