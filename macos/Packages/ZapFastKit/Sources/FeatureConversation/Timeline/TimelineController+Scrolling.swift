import AppKit
import ZapFastCore

// MARK: - Scrolling

extension TimelineController {
    var clip: NSClipView { scrollView.contentView }

    var isAtBottom: Bool {
        clip.bounds.maxY >= tableView.bounds.height - edgeSlack
    }

    /// Where the timeline goes in its pane, the room left at its top for
    /// the title bar, and at its bottom for the composer it scrolls under.
    /// A reader at the newest message stays there as the composer grows or
    /// shrinks.
    func place(frame: CGRect, topInset: CGFloat, bottomInset: CGFloat = 0) {
        let insets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        let moved = scrollView.frame != frame
        let reinset = clip.contentInsets.top != topInset || clip.contentInsets.bottom != bottomInset
        guard moved || reinset else { return }
        let follow = followsBottom
        let anchor = follow ? nil : readingAnchor()
        scrollView.frame = frame
        if reinset {
            scrollView.contentInsets = insets
            // The bar runs between the title bar and the composer, never
            // under either.
            scrollView.scrollerInsets = insets
        }
        if follow {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    func scrollToBottom(animated: Bool = false) {
        guard !items.isEmpty else { return }
        tableView.layoutSubtreeIfNeeded()
        let insets = clip.contentInsets
        let bottom = max(tableView.bounds.height - clip.bounds.height + insets.bottom, -insets.top)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
            scrollView.reflectScrolledClipView(clip)
            return
        }
        followsBottom = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: bottom))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(self.clip)
                // Rows that arrived during the animation are below it now.
                if self.followsBottom { self.scrollToBottom() }
            }
        }
    }

    func perform(_ kind: TimelineScroll) {
        switch kind {
        case .bottom:
            scrollToBottom(animated: true)
        case .top:
            scroll(toY: -clip.contentInsets.top)
        case .pageUp, .pageDown:
            let insets = clip.contentInsets
            let page = max(40, clip.bounds.height - insets.top - insets.bottom - 40)
            scroll(toY: clip.bounds.minY + (kind == .pageUp ? -page : page))
        }
    }

    /// Scrolls to `y`, kept within the content, animated unless Reduce
    /// Motion is on.
    private func scroll(toY y: CGFloat) {
        tableView.layoutSubtreeIfNeeded()
        let insets = clip.contentInsets
        let lowest = -insets.top
        let highest = max(lowest, tableView.bounds.height - clip.bounds.height + insets.bottom)
        let target = NSPoint(x: clip.bounds.minX, y: min(max(y, lowest), highest))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            clip.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(self.clip)
            }
        }
    }

    /// The chat just opened starts at its unread divider, at the top of the
    /// view (or as near as the content allows), once its rows are here.
    func placeUnreadDivider() {
        guard placesUnread, !items.isEmpty else { return }
        placesUnread = false
        // The message jumped to wins over the unread divider.
        guard pendingJump == nil, let index = items.firstIndex(where: { $0.id == "unread" }) else { return }
        tableView.layoutSubtreeIfNeeded()
        let insets = clip.contentInsets
        let lowest = -insets.top
        let highest = max(lowest, tableView.bounds.height - clip.bounds.height + insets.bottom)
        let top = min(max(tableView.rect(ofRow: index).minY - insets.top, lowest), highest)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scrollView.reflectScrolledClipView(clip)
        followsBottom = isAtBottom
    }

    /// Centres the message a jump asked for. A message not in the rows yet
    /// waits for the update that brings its page.
    func performPendingJump() {
        guard let jump = pendingJump, jump.key.chat == chatID,
              let index = items.firstIndex(where: { $0.id == jump.key.message }) else { return }
        pendingJump = nil
        handledJump = jump.token
        tableView.layoutSubtreeIfNeeded()
        let insets = clip.contentInsets
        let visibleHeight = clip.bounds.height - insets.top - insets.bottom
        let row = tableView.rect(ofRow: index)
        let lowest = -insets.top
        let highest = max(lowest, tableView.bounds.height - clip.bounds.height + insets.bottom)
        let top = min(max(row.midY - visibleHeight / 2 - insets.top, lowest), highest)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scrollView.reflectScrolledClipView(clip)
        followsBottom = isAtBottom
        report()
    }

    /// The first message on screen and how far its top sits below the
    /// clip's top. Chips are skipped: an older page from the same day moves
    /// the day's separator up with it.
    func readingAnchor() -> (id: String, offset: CGFloat)? {
        let visible = tableView.rows(in: clip.bounds)
        guard visible.length > 0 else { return nil }
        for row in visible.location..<min(visible.location + visible.length + 1, items.count) {
            if case .chip = items[row] { continue }
            return (items[row].id, tableView.rect(ofRow: row).minY - clip.bounds.minY)
        }
        return nil
    }

    func restore(_ anchor: (id: String, offset: CGFloat)) {
        guard let index = items.firstIndex(where: { $0.id == anchor.id }) else { return }
        tableView.layoutSubtreeIfNeeded()
        let top = tableView.rect(ofRow: index).minY - anchor.offset
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Tells the view whether to offer the "newest message" button. Sent on
    /// the next turn: this can run inside a SwiftUI update.
    func report() {
        if followsBottom { newBelow = 0 }
        let state = ScrollState(atBottom: followsBottom, newBelow: newBelow)
        guard state != reported else { return }
        reported = state
        let onScrollState = onScrollState
        DispatchQueue.main.async { onScrollState(state) }
    }

    @objc func scrolled(_ notification: Notification) {
        tableView.scrolled()
        // A page hung from a name or photo goes with what scrolls away.
        if senderPopover?.isShown == true { senderPopover?.close() }
        followsBottom = isAtBottom
        report()
        guard clip.bounds.minY + clip.contentInsets.top < prefetchDistance, !items.isEmpty, !reachTopScheduled else {
            return
        }
        // Asked on the next turn: this can run inside a table update.
        reachTopScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.reachTopScheduled = false
                self.onReachTop()
            }
        }
    }
}
