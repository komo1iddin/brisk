import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// The message list: an `NSTableView` island, because a chat can hold
/// thousands of rows and needs exact control over scroll position when
/// older pages arrive above what the person is reading.
struct MessageTimeline: NSViewRepresentable {
    let chatID: String
    let rows: [TimelineRow]
    let chat: ChatSummary?
    let model: AppModel
    let jump: JumpRequest?
    let theme: ChatTheme
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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            chatID: chatID,
            rows: rows,
            content: TimelineController.Content(
                chat: chat, model: model, theme: theme, textScale: model.preferences.textScale
            ),
            jump: jump,
            scrollRequest: scrollRequest,
            onReachTop: onReachTop,
            onScrollState: onScrollState
        )
    }
}
