import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The open chat's timeline. It reads only that chat's conversation (and
/// jumps, scrolls and the unread divider), so a message, a download or a
/// name change elsewhere does not reach it, and its inputs compare equal
/// whenever the parent redraws.
struct TimelineContainer: View {
    let chatID: String
    let isGroup: Bool
    let theme: ChatTheme
    let model: AppModel
    let onScrollState: (TimelineController.ScrollState) -> Void

    var body: some View {
        let conversation = model.conversations.conversation(chatID)
        MessageTimeline(
            chatID: chatID,
            messages: conversation.messages,
            revision: conversation.messagesRevision,
            isGroup: isGroup,
            model: model,
            style: TimelineStyle(theme: theme, textScale: model.preferences.textScale),
            unread: model.unreadDivider?.chat == chatID ? model.unreadDivider : nil,
            selecting: model.selection?.chat == chatID,
            jump: model.jump,
            scrollRequest: model.timelineScroll,
            onReachTop: { [model, chatID] in model.loadOlder(in: chatID) },
            onScrollState: onScrollState
        )
    }
}

/// The message list: an `NSTableView` island, because a chat can hold
/// thousands of rows and needs exact control over scroll position when
/// older pages arrive above what the person is reading.
struct MessageTimeline: NSViewRepresentable {
    let chatID: String
    let messages: [MessageRecord]
    let revision: Int
    let isGroup: Bool
    let model: AppModel
    let style: TimelineStyle
    let unread: UnreadDivider?
    /// Messages are being picked: every row is the SwiftUI row, which draws
    /// the checkboxes.
    let selecting: Bool
    let jump: JumpRequest?
    /// A scroll to make once.
    let scrollRequest: TimelineScrollRequest?
    let onReachTop: () -> Void
    let onScrollState: (TimelineController.ScrollState) -> Void

    func makeCoordinator() -> TimelineController {
        TimelineController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    /// Whatever it is offered: without an answer SwiftUI asks the scroll
    /// view's intrinsic size, and every row the table adds while scrolling
    /// sent the whole window through SwiftUI layout again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 400))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            chatID: chatID,
            messages: messages,
            revision: revision,
            isGroup: isGroup,
            model: model,
            style: style,
            unread: unread,
            selecting: selecting,
            jump: jump,
            scrollRequest: scrollRequest,
            onReachTop: onReachTop,
            onScrollState: onScrollState
        )
    }
}
