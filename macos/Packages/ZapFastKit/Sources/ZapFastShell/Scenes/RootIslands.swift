import FeatureLock
import FeatureOnboarding
import SwiftUI
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The main window's alerts and sheets that belong to no chat: confirming
/// a chat action, a group invite, a chat's theme, the keyboard shortcuts,
/// and what came from the Share menu. An island that draws nothing.
struct RootPresenters: View {
    @Bindable var model: AppModel

    var body: some View {
        Color.clear
            .chatConfirmationAlert(model: model)
            .groupInviteSheet(model: model)
            .chatThemeSheet(model: model)
            .sheet(isPresented: $model.shortcutsShown) { ShortcutsSheet() }
            // The Share menu's sheet waits for the lock and the link.
            .sheet(item: sharing) { request in ShareSheet(request: request, model: model) }
            .opensInviteLinks(model: model)
            // The default theme's colour, not the system accent, tints the app.
            .tint(model.chatTheme(for: nil).accent)
    }

    private var sharing: Binding<ShareRequest?> {
        Binding(
            get: { model.appLock.isLocked || !model.isLinked ? nil : model.shareRequest },
            set: { if $0 == nil, !model.appLock.isLocked { model.shareRequest = nil } }
        )
    }
}

/// The lock screen or linking, filling the window in place of the chats.
struct RootScreen: View {
    let model: AppModel
    let locked: Bool

    var body: some View {
        Group {
            if locked {
                // Nothing else is drawn, not even sheets over the chats.
                LockScreen(model: model)
            } else {
                LinkingView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(model.chatTheme(for: nil).accent)
    }
}

/// The notices over the top of the window.
struct RootNotices: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NoticeStack(model: model)
            .animation(.zf(reduceMotion), value: model.notices)
            .tint(model.chatTheme(for: nil).accent)
    }
}

/// Info and error notices, newest at the bottom, each dismissing itself.
struct NoticeStack: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Metrics.s) {
            ForEach(model.notices) { notice in
                NoticeBanner(text: notice.text, isError: notice.kind == .error) {
                    model.dismissNotice(notice)
                }
                .frame(maxWidth: 420)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .task {
                    // Said aloud, since it goes away on its own; with
                    // VoiceOver on it stays twice as long.
                    AccessibilityNotification.Announcement(notice.text).post()
                    let seconds = notice.kind == .error ? 8.0 : 4.0
                    let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
                    try? await Task.sleep(for: .seconds(voiceOver ? seconds * 2 : seconds))
                    model.dismissNotice(notice)
                }
            }
        }
        .padding(.horizontal, Metrics.l)
    }
}
