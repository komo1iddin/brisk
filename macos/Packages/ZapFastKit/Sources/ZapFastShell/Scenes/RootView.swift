import FeatureChats
import FeatureConversation
import FeatureLock
import FeatureOnboarding
import SwiftUI
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The main window's content: linking until there is an account, then the
/// chat list and the open conversation.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.appLock.isLocked {
                // Nothing else is drawn, not even sheets over the chats.
                LockScreen(model: model)
            } else if model.isLinked {
                MainSplitView(model: model)
            } else {
                LinkingView(model: model)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // The default theme's colour, not the system accent, tints the app.
        .tint(model.chatTheme(for: nil).accent)
        .chatConfirmationAlert(model: model)
        .groupInviteSheet(model: model)
        .chatThemeSheet(model: model)
        .sheet(isPresented: $model.shortcutsShown) { ShortcutsSheet() }
        .opensInviteLinks(model: model)
        .overlay(alignment: .top) {
            NoticeStack(model: model)
        }
        .animation(.zf(reduceMotion), value: model.notices)
    }
}

/// The sidebar and the conversation. `NavigationSplitView` autosaves the
/// column widths and gives each column its own part of the title bar.
private struct MainSplitView: View {
    @Bindable var model: AppModel
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ChatListView(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            if let chatID = model.selectedChatID {
                ConversationView(chatID: chatID, model: model)
                    .id(chatID)
            } else {
                ContentUnavailableView(
                    "No chat selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a chat from the list.")
                )
            }
        }
        // Closing the window locks the Locked folder again, as upstream's does.
        .onDisappear { model.closeLockedChats() }
    }
}

/// Info and error notices, newest at the bottom, each dismissing itself.
private struct NoticeStack: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: Metrics.s) {
            ForEach(model.notices) { notice in
                NoticeBanner(text: notice.text, isError: notice.kind == .error) {
                    model.dismissNotice(notice)
                }
                .frame(maxWidth: 420)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(notice.kind == .error ? 8 : 4))
                    model.dismissNotice(notice)
                }
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, Metrics.l)
    }
}
