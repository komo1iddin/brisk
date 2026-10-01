import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What floats over the timeline and takes no clicks: the spinner while
/// older messages come, and the note in a chat with nothing yet.
struct ConversationOverlay: View {
    let pane: ConversationPaneState

    var body: some View {
        ZStack {
            if pane.empty {
                EmptyConversation()
            }
            LoadingOlder(loading: pane.loadingOlder)
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
    /// Says whether the chat takes messages: read from the chat here, its
    /// every message would make the composer again.
    let pane: ConversationPaneState

    var body: some View {
        if let selection = model.selection, selection.chat == chatID {
            SelectionBar(selection: selection, model: model)
        } else if let chat = pane.closedChat {
            ReadOnlyBar(chat: chat)
        } else {
            ComposerBar(chatID: chatID, model: model)
        }
    }
}
