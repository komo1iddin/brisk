import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// What the chat's header and the presenters share: a request from the
/// info popover, which closes first and leaves the dialog to the window.
@Observable
final class ConversationChrome {
    var infoRequest: InfoRequest?
}

/// The chat's sheets, dialogs and the windows laid over it (the media
/// editor and viewer), in a SwiftUI island that draws nothing: SwiftUI
/// presents them on the island's window.
struct ConversationPresenters: View {
    let chatID: String
    @Bindable var model: AppModel
    @Bindable var chrome: ConversationChrome

    var body: some View {
        let theme = model.chatTheme(for: chatID)
        Color.clear
            // Photos and videos about to go out, in a window over this one.
            .background {
                MediaEditorPresenter(
                    chatID: chatID, model: model, isPresented: model.isEditingMedia(in: chatID), theme: theme
                )
            }
            // A photo or video opened from its bubble, in a window over this one.
            .background {
                MediaViewerPresenter(
                    chatID: chatID, model: model, isPresented: model.mediaViewer?.chat == chatID, theme: theme
                )
            }
            .infoDialogs($chrome.infoRequest, model: model)
            .sheet(item: forwarding) { request in
                ForwardSheet(request: request, model: model)
            }
            .sheet(item: pollResults) { key in
                PollResultsSheet(key: key, model: model)
            }
            .sheet(item: messageInfo) { key in
                MessageInfoSheet(key: key, model: model)
            }
            .sheet(item: stickerPack) { preview in
                StickerPackSheet(preview: preview, model: model)
            }
            .sheet(item: interactiveList) { request in
                InteractiveListSheet(request: request, model: model)
            }
            .environment(\.chatTheme, theme)
            .tint(theme.accent)
            .opensInviteLinks(model: model)
    }

    private var forwarding: Binding<ForwardRequest?> {
        Binding(
            get: { model.forwarding.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { if $0 == nil { model.cancelForward() } }
        )
    }

    private var pollResults: Binding<MessageKey?> {
        Binding(
            get: { model.pollResults.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { model.pollResults = $0 }
        )
    }

    private var stickerPack: Binding<StickerPackPreview?> {
        Binding(
            get: { model.stickerPackPreview.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { model.stickerPackPreview = $0 }
        )
    }

    private var interactiveList: Binding<InteractiveListRequest?> {
        Binding(
            get: { model.interactiveList.flatMap { $0.key.chat == chatID ? $0 : nil } },
            set: { model.interactiveList = $0 }
        )
    }

    private var messageInfo: Binding<MessageKey?> {
        Binding(
            get: { model.messageInfo.flatMap { $0.chat == chatID ? $0 : nil } },
            set: { model.messageInfo = $0 }
        )
    }
}

/// The chat's picture and name at the head of the window, in the toolbar.
struct ConversationHeader: View {
    /// What the header shows of the chat, read by its controller.
    struct Content: Equatable {
        /// The chat without its latest activity (`withoutActivity`).
        var chat: ChatSummary
        var title: String
        /// A group's members, its subtitle while nobody types.
        var members: String
    }

    let content: Content
    let model: AppModel
    let chrome: ConversationChrome

    var body: some View {
        let theme = model.chatTheme(for: content.chat.id)
        ChatHeader(chat: content.chat, title: content.title, members: content.members, model: model) { request in
            // The popover goes first; the window answers.
            model.closeInfo()
            Task { @MainActor in chrome.infoRequest = request }
        }
        .environment(\.chatTheme, theme)
        .tint(theme.accent)
        .opensInviteLinks(model: model)
    }
}
