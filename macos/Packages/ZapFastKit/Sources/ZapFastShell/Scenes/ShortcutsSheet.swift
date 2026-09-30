import SwiftUI
import ZapFastDesign

/// Every keyboard shortcut in one place (upstream's shortcuts dialog), from
/// Help › Keyboard Shortcuts or ⌘/.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let keys: String
        let does: LocalizedStringKey
        var id: String { keys }
    }

    private let groups: [(title: LocalizedStringKey, items: [Shortcut])] = [
        ("Chats", [
            Shortcut(keys: "⌘N", does: "New chat"),
            Shortcut(keys: "⇧⌘] / ⇧⌘[", does: "Next / previous chat"),
            Shortcut(keys: "⌥⌘F", does: "Search all chats"),
            Shortcut(keys: "⌘I", does: "Chat info"),
            Shortcut(keys: "⇧⌘R / ⇧⌘U", does: "Mark read / unread"),
        ]),
        ("Messages", [
            Shortcut(keys: "⌘F", does: "Search the open chat"),
            Shortcut(keys: "⌘G / ⇧⌘G", does: "Next / previous match"),
            Shortcut(keys: "⌥⌘↓", does: "Newest message"),
            Shortcut(keys: "Page Up / Page Down", does: "Scroll the messages"),
            Shortcut(keys: "Home / End", does: "Oldest / newest message (empty field)"),
            Shortcut(keys: "⌘-click / ⇧-click", does: "Select messages / a run of them"),
            Shortcut(keys: "Esc", does: "Cancel a reply, an edit or a selection"),
        ]),
        ("Writing", [
            Shortcut(keys: "⌘L", does: "Write a message"),
            Shortcut(keys: "Return / ⇧Return", does: "Send / new line"),
            Shortcut(keys: "⌘Return", does: "Send, whatever Return does"),
            Shortcut(keys: "↑", does: "Edit your last message (empty field)"),
            Shortcut(keys: "@ / :", does: "Mention someone / complete an emoji"),
            Shortcut(keys: "⌘V", does: "Paste text, a picture or files"),
        ]),
        ("ZapFast", [
            Shortcut(keys: "⌘+ / ⌘− / ⌘0", does: "Bigger / smaller / actual size text"),
            Shortcut(keys: "⌘,", does: "Settings"),
            Shortcut(keys: "⌃⌘L", does: "Lock ZapFast"),
            Shortcut(keys: "⌘/", does: "These shortcuts"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(groups, id: \.items.first?.keys) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            LabeledContent {
                                Text(item.keys)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(item.does)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Metrics.m)
        }
        .frame(width: 460, height: 560)
    }
}
