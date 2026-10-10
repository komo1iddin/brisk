/// Keyboard shortcuts, and the text size two of them change.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: keyboard

    public func scrollTimeline(_ kind: TimelineScroll) {
        guard selectedChatID != nil else { return }
        timelineScroll = TimelineScrollRequest(kind: kind)
    }

    /// Opens the chat above or below the open one in the sidebar, wrapping
    /// around, as upstream's Alt+↑ / Alt+↓ do; with none open, the first.
    public func selectAdjacentChat(forward: Bool) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let next = if let current = selectedChatID, let index = order.firstIndex(of: current) {
            order[(index + (forward ? 1 : order.count - 1)) % order.count]
        } else {
            order[0]
        }
        // Stepping through the Unread list must not shift it underfoot.
        keepUnread(next)
        selectedChatID = next
    }

    /// ⌘1 to ⌘9: the chat at that place in the sidebar, as Messages does.
    public func selectChat(atSidebarPlace place: Int) {
        guard sidebarOrder.indices.contains(place) else { return }
        let chat = sidebarOrder[place]
        keepUnread(chat)
        selectedChatID = chat
    }

    /// A chat opened from the sidebar: kept while it shows the Unread list.
    public func keepUnread(_ chat: String) {
        guard sidebarKeepsUnread else { return }
        keptUnread.insert(chat)
    }

    /// The sidebar changed its filter, label or folder.
    public func forgetKeptUnread() {
        keptUnread = []
    }

    /// Upstream's "Mute all channels" / "Unmute all channels".
    public var allChannelsMuted: Bool {
        chats.channelCount > 0 && chats.mutedChannelCount == chats.channelCount
    }

    public func muteAllChannels(_ mute: Bool) {
        for channel in chats.channels where chats.isMuted(channel) != mute {
            setMuted(until: mute ? 0 : nil, chat: channel.id)
        }
    }

    /// Puts the cursor in the composer (upstream's Ctrl+L).
    public func focusComposer() {
        guard selectedChatID != nil else { return }
        composerFocusRequests += 1
    }

    // MARK: Intents: text size

    public static let textScales = stride(from: 0.8, through: 1.6, by: 0.1).map { ($0 * 10).rounded() / 10 }

    /// View › Bigger / Smaller: a tenth at a time, as upstream's zoom steps.
    public func changeTextSize(bigger: Bool) {
        let scales = Self.textScales
        let current = scales.firstIndex { abs($0 - preferences.textScale) < 0.05 } ?? scales.firstIndex(of: 1)!
        let next = min(max(current + (bigger ? 1 : -1), 0), scales.count - 1)
        preferences.textScale = scales[next]
    }

    public func resetTextSize() {
        preferences.textScale = 1
    }

    public var canMakeTextBigger: Bool { preferences.textScale < Self.textScales.last! - 0.05 }
    public var canMakeTextSmaller: Bool { preferences.textScale > Self.textScales.first! + 0.05 }
}
