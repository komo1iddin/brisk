import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore

/// Owns the timeline's table: applies row changes as inserts and reloads,
/// keeps the reader's place when older messages arrive above, follows new
/// messages while the reader is at the bottom, and asks for older pages
/// near the top.
final class TimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// What every row needs besides its own data.
    struct Content {
        var chat: ChatSummary?
        var model: AppModel?
    }

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rows: [TimelineRow] = []
    private var chatID: String?
    private var content = Content()
    private var onReachTop: () -> Void = {}
    private let heights = RowHeights()
    private var lastWidth: CGFloat = 0
    /// The reader is at the newest message, so new ones scroll into view.
    private var followsBottom = true
    /// The last jump scrolled to, so each is done once.
    private var handledJump: UUID?

    /// Within this distance of an edge counts as being at it.
    private let edgeSlack: CGFloat = 48
    /// Older pages are requested this far before the top is reached.
    private let prefetchDistance: CGFloat = 600

    func makeScrollView() -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.focusRingType = .none
        tableView.setAccessibilityLabel(String(localized: "Messages"))
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // Content scrolls under the title bar; AppKit insets it so nothing hides.
        scrollView.automaticallyAdjustsContentInsets = true

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: tableView
        )
        return scrollView
    }

    // MARK: Updates

    func update(
        chatID: String,
        rows new: [TimelineRow],
        content: Content,
        jump: JumpRequest?,
        onReachTop: @escaping () -> Void
    ) {
        self.content = content
        self.onReachTop = onReachTop

        if chatID != self.chatID {
            self.chatID = chatID
            rows = new
            heights.removeAll()
            tableView.reloadData()
            followsBottom = true
            scrollToBottom()
        } else if new != rows {
            apply(new)
        }
        if let jump, jump.key.chat == chatID, jump.token != handledJump {
            scroll(toMessage: jump.key.message, token: jump.token)
        }
    }

    private func apply(_ new: [TimelineRow]) {
        let old = rows
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        let follow = followsBottom

        // Same rows, some changed in place (a tick, a reaction, a download).
        if oldIDs == newIDs {
            rows = new
            let changed = IndexSet(new.indices.filter { new[$0] != old[$0] })
            reload(changed)
            if follow { scrollToBottom() }
            return
        }

        // An older page arrived above: keep the reader's place.
        if !oldIDs.isEmpty, newIDs.count > oldIDs.count, Array(newIDs.suffix(oldIDs.count)) == oldIDs {
            let anchor = topAnchor()
            let added = newIDs.count - oldIDs.count
            rows = new
            tableView.insertRows(at: IndexSet(integersIn: 0..<added), withAnimation: [])
            let shifted = IndexSet(new.indices.dropFirst(added).filter { new[$0] != old[$0 - added] })
            reload(shifted)
            restore(anchor, shiftedBy: added)
            return
        }

        // Anything else: removals and insertions, then in-place changes.
        let difference = newIDs.difference(from: oldIDs)
        rows = new
        tableView.beginUpdates()
        for removal in difference.removals.reversed() {
            if case .remove(let offset, _, _) = removal {
                tableView.removeRows(at: [offset], withAnimation: .effectFade)
            }
        }
        for insertion in difference.insertions {
            if case .insert(let offset, _, _) = insertion {
                tableView.insertRows(at: [offset], withAnimation: follow ? [] : .effectFade)
            }
        }
        tableView.endUpdates()

        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = new.indices.filter { index in
            guard let before = previous[new[index].id] else { return false }
            return before != new[index]
        }
        reload(IndexSet(changed))
        if follow { scrollToBottom() }
    }

    private func reload(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        for index in indexes { heights.invalidate(rows[index].id) }
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: [0])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    // MARK: Scrolling

    private var clip: NSClipView { scrollView.contentView }

    private var isAtBottom: Bool {
        clip.bounds.maxY >= tableView.bounds.height - edgeSlack
    }

    private func scrollToBottom() {
        guard !rows.isEmpty else { return }
        tableView.layoutSubtreeIfNeeded()
        tableView.scrollRowToVisible(rows.count - 1)
    }

    /// Centres a message in view. A message not in the rows yet waits for
    /// the next update, when its page has arrived.
    private func scroll(toMessage id: String, token: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        handledJump = token
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
    }

    /// The first visible row and how far its top sits below the clip's top.
    private func topAnchor() -> (row: Int, offset: CGFloat)? {
        let visible = tableView.rows(in: clip.bounds)
        guard visible.length > 0 else { return nil }
        let row = visible.location
        return (row, tableView.rect(ofRow: row).minY - clip.bounds.minY)
    }

    private func restore(_ anchor: (row: Int, offset: CGFloat)?, shiftedBy added: Int) {
        guard let anchor else { return }
        tableView.layoutSubtreeIfNeeded()
        let top = tableView.rect(ofRow: anchor.row + added).minY - anchor.offset
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled(_ notification: Notification) {
        followsBottom = isAtBottom
        if clip.bounds.minY + clip.contentInsets.top < prefetchDistance, !rows.isEmpty {
            onReachTop()
        }
    }

    @objc private func resized(_ notification: Notification) {
        let width = tableView.bounds.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        heights.removeAll()
        let follow = followsBottom
        let anchor = topAnchor()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        if follow { scrollToBottom() } else { restore(anchor, shiftedBy: 0) }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: HostingCell.identifier, owner: nil) as? HostingCell
            ?? HostingCell()
        cell.show(rowView(rows[row]))
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = rows[row]
        return heights.height(for: item, width: tableView.bounds.width) { width in
            RowMeasurer.shared.height(of: rowView(item), width: width)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    @ViewBuilder
    private func rowView(_ row: TimelineRow) -> some View {
        switch row {
        case .day(_, let title):
            DaySeparator(title: title)
        case .message(let message, let startsRun):
            if let model = content.model {
                MessageRow(message: message, startsRun: startsRun, chat: content.chat, model: model)
            }
        }
    }
}

// MARK: - Cells and measuring

/// A table cell showing one SwiftUI row.
private final class HostingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineHostingCell")

    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: some View) {
        host.rootView = AnyView(view)
    }
}

/// Measures rows off-screen with one reusable hosting controller.
private final class RowMeasurer {
    static let shared = RowMeasurer()
    private let controller = NSHostingController(rootView: AnyView(EmptyView()))

    func height(of view: some View, width: CGFloat) -> CGFloat {
        controller.rootView = AnyView(view)
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return max(1, ceil(size.height))
    }
}

/// Row heights by row id, valid for one width and one version of the row.
private final class RowHeights {
    private struct Entry {
        var width: CGFloat
        var row: TimelineRow
        var height: CGFloat
    }

    private var entries: [String: Entry] = [:]

    func height(for row: TimelineRow, width: CGFloat, measure: (CGFloat) -> CGFloat) -> CGFloat {
        if let entry = entries[row.id], entry.width == width, entry.row == row {
            return entry.height
        }
        let height = measure(width)
        entries[row.id] = Entry(width: width, row: row, height: height)
        return height
    }

    func invalidate(_ id: String) {
        entries[id] = nil
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}
