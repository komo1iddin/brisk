import AppKit
import ZapFastBridge
import ZapFastCore

// MARK: - Dragging across messages

/// Where a drag's events come from. AppKit's own, except in a test, which
/// sends its own: a test process cannot take them from the application's
/// queue without ending its run loop.
struct SweepEvents {
    /// The next mouse event within the time, or nil when none came.
    var next: (NSWindow, TimeInterval) -> NSEvent?
    /// Puts a release back for whoever takes the press next.
    var repost: (NSEvent) -> Void

    static let system = SweepEvents(
        next: { window, timeout in
            window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: timeout),
                inMode: .eventTracking, dequeue: true
            )
        },
        repost: { NSApp.postEvent($0, atStart: true) }
    )
}

extension TimelineController {
    static var sweepEvents = SweepEvents.system

    /// How far the pointer goes before a press counts as a drag.
    private static let sweepSlop: CGFloat = 4
    /// Within this distance of the top or bottom edge the timeline scrolls.
    private static let sweepZone: CGFloat = 36
    /// How often a held pointer is read, to scroll and to pick what comes
    /// under it.
    private static let sweepTick: TimeInterval = 1.0 / 30

    /// A press on a row's empty space, or on any row while picking, that
    /// becomes a drag: every message the pointer passes is picked, or put
    /// back when the press took the first out. The pointer at the top or
    /// bottom of the timeline scrolls it. Runs until the button goes up.
    ///
    /// A press that never moves is a click. Picking, that was the press's own
    /// work already; otherwise the release is put back for the table, which
    /// is where the press goes next, and this returns false.
    func sweep(fromMessage id: String, event: NSEvent) -> Bool {
        guard let model, let window = tableView.window, let chat = chatID,
              let start = message(id), model.canSelect(start) else { return false }
        let picking = model.selection?.chat == chat
        let origin = event.locationInWindow
        var dragging = false
        var sweep: MessageSweep?
        var reached: String?
        while tableView.window === window, chatID == chat {
            let next = Self.sweepEvents.next(window, Self.sweepTick)
            if let next, next.type == .leftMouseUp {
                if !dragging, !picking {
                    Self.sweepEvents.repost(next)
                    return false
                }
                return dragging
            }
            let location = next?.locationInWindow ?? window.mouseLocationOutsideOfEventStream
            if !dragging {
                guard next != nil, hypot(location.x - origin.x, location.y - origin.y) >= Self.sweepSlop else { continue }
                dragging = true
                if !picking { model.select(start) }
                sweep = model.beginSweep(from: start)
            }
            // Nothing is picked (the press took the last one out): wait for the release.
            guard let sweep else { continue }
            scrollForSweep(towards: location)
            if let over = messageForSweep(at: location, startedAt: id), over.id != reached {
                reached = over.id
                model.sweep(sweep, to: over)
            }
        }
        return dragging
    }

    /// Scrolls while the pointer is near the top or bottom of the timeline,
    /// faster the nearer the edge, and past it.
    private func scrollForSweep(towards location: NSPoint) {
        let insets = clip.contentInsets
        let point = clip.convert(location, from: nil)
        let top = clip.bounds.minY + insets.top
        let bottom = clip.bounds.maxY - insets.bottom
        var delta: CGFloat = 0
        if point.y < top + Self.sweepZone {
            delta = -Self.sweepSpeed(top + Self.sweepZone - point.y)
        } else if point.y > bottom - Self.sweepZone {
            delta = Self.sweepSpeed(point.y - (bottom - Self.sweepZone))
        }
        guard delta != 0 else { return }
        let lowest = -insets.top
        let highest = max(lowest, tableView.bounds.height - clip.bounds.height + insets.bottom)
        let y = min(max(clip.bounds.minY + delta, lowest), highest)
        guard y != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func sweepSpeed(_ distance: CGFloat) -> CGFloat {
        min(2 + distance * 0.5, 40)
    }

    /// The message under the pointer, kept within what is on screen: past
    /// the top or bottom it is the first or last row there. A day chip or
    /// the unread divider is no message, so the nearest one towards where
    /// the drag began stands in.
    private func messageForSweep(at location: NSPoint, startedAt id: String) -> MessageRecord? {
        let insets = clip.contentInsets
        let top = clip.bounds.minY + insets.top
        let bottom = clip.bounds.maxY - insets.bottom - 1
        guard top < bottom, let anchor = items.firstIndex(where: { $0.id == id }) else { return nil }
        let y = min(max(tableView.convert(location, from: nil).y, top), bottom)
        var row = tableView.row(at: NSPoint(x: tableView.bounds.midX, y: y))
        guard row >= 0 else { return nil }
        let step = anchor >= row ? 1 : -1
        while row != anchor, items.indices.contains(row), items[row].message == nil { row += step }
        return items.indices.contains(row) ? items[row].message : nil
    }
}
