import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What floats over the timeline and takes no clicks: the spinner while
/// older messages come, and the note in a chat with nothing yet.
struct ConversationOverlay: View {
    let chatID: String
    let model: AppModel

    var body: some View {
        ZStack {
            EmptyConversation(chatID: chatID, model: model)
            LoadingOlder(chatID: chatID, model: model)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The "newest message" button, while the reader is away from it.
struct NewestMessageIsland: View {
    /// Room for the button and its count, which hangs off its corner.
    static let size: CGFloat = 50

    let pane: ConversationPaneState
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            if !pane.scroll.atBottom {
                NewestMessageButton(newBelow: pane.scroll.newBelow, action: action)
                    .padding(8)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.zf(reduceMotion), value: pane.scroll.atBottom)
    }
}

/// Under the timeline: the composer, the bar of selected messages, or why
/// this chat cannot be written to.
struct ConversationBottomBar: View {
    let chatID: String
    let model: AppModel

    var body: some View {
        let chat = model.chats.chat(chatID)
        if let selection = model.selection, selection.chat == chatID {
            SelectionBar(selection: selection, model: model)
        } else if let chat, !ConversationView.canSend(chat) {
            ReadOnlyBar(chat: chat)
        } else {
            ComposerBar(chatID: chatID, model: model)
        }
    }
}
