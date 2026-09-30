import SwiftUI
import ZapFastCore

/// Menu bar additions. Standard menus (Edit, Window, Help) come from the system.
struct ZapFastCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Chat") {
            Button("Mark as Read") {
                if let id = model.selectedChatID { model.markRead(id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedChatID == nil || locked)

            Button("Mark as Unread") {
                if let id = model.selectedChatID { model.markUnread(id) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.selectedChatID == nil || locked)

            Button("Show Chat Info") { model.showInfo() }
                .keyboardShortcut("i")
                .disabled(model.selectedChatID == nil || locked)

            Divider()

            // As Safari's tabs, and WhatsApp's own keys for chats.
            Button("Next Chat") { model.selectAdjacentChat(forward: true) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(locked)
            Button("Previous Chat") { model.selectAdjacentChat(forward: false) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(locked)

            Button("Write a Message") { model.focusComposer() }
                .keyboardShortcut("l")
                .disabled(model.selectedChatID == nil || locked)
            Button("Scroll to Newest Message") { model.scrollTimeline(.bottom) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.selectedChatID == nil || locked)

            Divider()

            Button("Close Chat") { model.selectedChatID = nil }
                .disabled(model.selectedChatID == nil || locked)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Chat…") { model.newChatShown = true }
                .keyboardShortcut("n")
                .disabled(!model.isLinked || locked)

            Button("Join Group with Link…") { model.askForInviteLink() }
                .disabled(!model.isLinked || locked)
        }

        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find in Chat…") { model.openChatSearch() }
                    .keyboardShortcut("f")
                    .disabled(model.selectedChatID == nil || locked)

                Button("Search All Chats") { model.focusSidebarSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(locked)

                Divider()

                Button("Find Next") { model.stepChatSearch(older: true) }
                    .keyboardShortcut("g")
                    .disabled(!hasChatHits || locked)

                Button("Find Previous") { model.stepChatSearch(older: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!hasChatHits || locked)
            }
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger") { model.changeTextSize(bigger: true) }
                .keyboardShortcut("+")
                .disabled(!model.canMakeTextBigger)
            Button("Smaller") { model.changeTextSize(bigger: false) }
                .keyboardShortcut("-")
                .disabled(!model.canMakeTextSmaller)
            Button("Actual Size") { model.resetTextSize() }
                .keyboardShortcut("0")
                .disabled(model.preferences.textScale == 1)
        }

        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { model.shortcutsShown = true }
                .keyboardShortcut("/")
                .disabled(locked)
        }

        CommandGroup(after: .appInfo) {
            Button("Reconnect") { model.reconnect() }
                .disabled(model.session.isConnected)
        }

        CommandGroup(after: .appSettings) {
            Button("Lock ZapFast") { model.appLock.lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(!model.appLock.isEnabled || model.appLock.isLocked)
        }
    }

    /// Nothing in the chats is reachable while the app lock is closed.
    private var locked: Bool {
        model.appLock.isLocked
    }

    private var hasChatHits: Bool {
        model.search.chat.map { !$0.hits.isEmpty } ?? false
    }
}
