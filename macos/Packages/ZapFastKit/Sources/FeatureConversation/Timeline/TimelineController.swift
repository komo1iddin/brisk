import AppKit
import Observation
import OSLog
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Owns the timeline's table.
///
/// What Telefast's spike measured, applied here:
/// - Row heights are known before the table asks. Plain text messages, most
///   of any chat, are measured off the main actor in parallel
///   (`TimelineLayoutEngine`) and drawn by Core Animation (`TextBubbleCell`);
///   only richer messages are SwiftUI rows, measured once per bubble width.
/// - A row depends on the width only through the widest a bubble may be, so
///   resizing a wide window costs nothing, and a narrow one is re-measured
///   once the drag ends, not on every frame of it.
/// - Nothing reads the stores per row: the view hands over the chat's
///   messages and their revision, and an unchanged revision is a no-op.
///
/// Changes keep the reader's place by message id, whatever moved above it,
/// and follow new messages while the reader is at the bottom.
final class TimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Whether the reader is at the newest message, and how many incoming
    /// messages arrived below while they were not.
    struct ScrollState: Equatable {
        var atBottom = true
        var newBelow = 0
    }

    enum Plan {
        /// A chip centred in the timeline: a day, or the unread divider.
        case chip(id: String, title: String, isDay: Bool)
        case text(TimelineRow, TextBubbleSource)
        case hosted(TimelineRow)
    }

    enum Item {
        case chip(id: String, title: String, isDay: Bool, height: CGFloat)
        case text(TimelineRow, TextBubbleLayout)
        case hosted(TimelineRow, height: CGFloat)

        var id: String {
            switch self {
            case .chip(let id, _, _, _): id
            case .text(let row, _), .hosted(let row, _): row.id
            }
        }

        var height: CGFloat {
            switch self {
            case .chip(_, _, _, let height), .hosted(_, let height): height
            case .text(_, let layout): layout.rowHeight
            }
        }

        var message: MessageRecord? {
            switch self {
            case .chip: nil
            case .text(let row, _), .hosted(let row, _):
                if case .message(let message, _) = row { message } else { nil }
            }
        }

        func differs(from other: Item) -> Bool {
            switch (self, other) {
            case let (.chip(_, a, _, _), .chip(_, b, _, _)): a != b
            case let (.text(_, a), .text(_, b)): a !== b
            case let (.hosted(a, ha), .hosted(b, hb)): a != b || ha != hb
            default: true
            }
        }
    }

    let scrollView = NSScrollView()
    let tableView = TimelineTableView()
    var chatID: String?
    private var revision: Int?
    private var messages: [MessageRecord] = []
    private var isGroup = false
    private(set) var style = TimelineStyle.standard
    private var colors = BubbleColors(TimelineStyle.standard)
    private var unread: UnreadDivider?
    private var selecting = false
    weak var model: AppModel?
    var onReachTop: () -> Void = {}
    var onScrollState: (ScrollState) -> Void = { _ in }

    var items: [Item] = []
    private var plans: [Plan] = []
    /// The bubble width the items are laid out for.
    private var widthLimit: CGFloat = 0

    private var textLayouts: [String: (source: TextBubbleSource, layout: TextBubbleLayout)] = [:]
    private var hostedHeights: [String: (row: TimelineRow, limit: CGFloat, scale: Double, height: CGFloat)] = [:]
    private var chipHeights: [String: CGFloat] = [:]
    /// Bumped by every preparation; a background layout that finishes after
    /// a newer one started is not installed.
    private var generation = 0

    /// The reader is at the newest message, so new ones scroll into view.
    var followsBottom = true
    /// Incoming messages that arrived below while the reader was elsewhere.
    var newBelow = 0
    var reported = ScrollState()
    /// The last jump scrolled to, so each is done once.
    var handledJump: UUID?
    var pendingJump: JumpRequest?
    /// The last scroll asked for (keys, the newest-message button), so
    /// each is done once.
    var handledScroll: UUID?
    /// The chat just opened; its unread divider goes to the top once its
    /// messages are here.
    var placesUnread = false
    private var highlighted: MessageKey?
    private var reactionTarget: MessageKey?
    private var namesChanged = false
    private var widthCheckScheduled = false
    var reachTopScheduled = false
    private var relayoutAfterLiveResize = false
    private var observers: [NSObjectProtocol] = []

    /// Within this distance of an edge counts as being at it.
    let edgeSlack: CGFloat = 48
    /// Older pages are requested this far before the top is reached.
    let prefetchDistance: CGFloat = 600
    /// More new text rows than this are measured in the background: a live
    /// message or two is laid out at once, a page of history off the main
    /// actor (60 messages took about 12 ms there, mostly link detection).
    private let backgroundThreshold = 8

    nonisolated private static let signposter = OSSignposter(subsystem: "ZapFast", category: "Timeline")

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
        tableView.identifier = .messageTimeline
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
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: clip)
        observers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let window = self.scrollView.window, sender == ObjectIdentifier(window) else { return }
                self.liveResizeEnded()
            }
        })
        observers.append(center.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleColors() }
        })
        return scrollView
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Updates

    func update(
        chatID: String,
        messages: [MessageRecord],
        revision: Int,
        isGroup: Bool,
        model: AppModel,
        style: TimelineStyle,
        unread: UnreadDivider?,
        selecting: Bool,
        jump: JumpRequest?,
        scrollRequest: TimelineScrollRequest?,
        onReachTop: @escaping () -> Void,
        onScrollState: @escaping (ScrollState) -> Void
    ) {
        self.onReachTop = onReachTop
        self.onScrollState = onScrollState
        // Pictures are decoded for the display the timeline is on.
        if let space = scrollView.window?.colorSpace?.cgColorSpace, space != DisplayImage.colorSpace {
            DisplayImage.colorSpace = space
        }
        if self.model !== model {
            self.model = model
            observeHighlight()
            observeReactionTarget()
        }
        if chatID != self.chatID || isGroup != self.isGroup {
            self.chatID = chatID
            self.isGroup = isGroup
            self.revision = nil
            items = []
            textLayouts = [:]
            hostedHeights = [:]
            generation += 1
            followsBottom = true
            placesUnread = true
            newBelow = 0
            handledScroll = scrollRequest?.token
            tableView.reloadData()
        }
        if let jump, jump.key.chat == chatID, jump.token != handledJump {
            pendingJump = jump
        }
        let restyled = style != self.style
        var changed = revision != self.revision || restyled || unread != self.unread || selecting != self.selecting
        if restyled {
            self.style = style
            colors = BubbleColors(style)
        }
        if selecting != self.selecting {
            // Rows swap between the drawn cell and the SwiftUI row, which
            // draws the checkboxes.
            self.selecting = selecting
        }
        self.unread = unread
        if revision != self.revision {
            self.revision = revision
            self.messages = messages
            changed = true
        }
        if changed {
            rebuild(restyled: restyled)
        } else {
            performPendingJump()
        }
        if let scrollRequest, scrollRequest.token != handledScroll {
            handledScroll = scrollRequest.token
            perform(scrollRequest.kind)
        }
        report()
    }

    /// Rows for the current messages: resolved on the main actor, measured
    /// wherever suits, installed on the main actor.
    private func rebuild(restyled: Bool = false) {
        let rows = TimelineRow.build(messages, unread: unread)
        plans = resolve(rows)
        prepare(limit: widthLimit > 0 ? widthLimit : currentWidthLimit(), restyled: restyled)
    }

    /// Names shown in rows come from the stores. Reading them under
    /// observation means a contact's new name updates the rows that show
    /// it, without the rows reading the stores themselves.
    private func resolve(_ rows: [TimelineRow]) -> [Plan] {
        guard let model else { return [] }
        let isGroup = isGroup
        let colors = colors
        let selecting = selecting
        return withObservationTracking {
            rows.map { row -> Plan in
                switch row {
                case let .day(id, title):
                    return .chip(id: id, title: title, isDay: true)
                case .unread(let count):
                    let title = String(AttributedString(localized: "^[\(count) unread message](inflect: true)").characters)
                    return .chip(id: row.id, title: title, isDay: false)
                case let .message(message, startsRun):
                    guard !selecting, case .text(let text, nil) = message.content else { return .hosted(row) }
                    let chats = model.chats
                    return .text(row, TextBubbleSource(
                        id: message.id,
                        fromMe: message.fromMe,
                        startsRun: startsRun,
                        text: text,
                        emojiOnly: BodyText.isOnlyEmoji(text),
                        mentions: message.mentions,
                        mentionNames: Dictionary(
                            message.mentions.map { ($0.id, chats.displayName($0.id)) },
                            uniquingKeysWith: { first, _ in first }
                        ),
                        senderName: startsRun && !message.fromMe && isGroup
                            ? chats.personName(message.sender, hint: message.senderName) : nil,
                        senderID: message.sender,
                        forwarded: message.forwarded,
                        quote: message.quoted.map {
                            .init(name: chats.displayName($0.sender, hint: $0.senderName), summary: $0.summary, senderID: $0.sender)
                        },
                        edited: message.edited,
                        timestamp: message.timestamp,
                        status: message.status,
                        reactions: message.reactions,
                        colors: colors
                    ))
                }
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.namesDidChange() }
            }
        }
    }

    /// A burst of contact updates is folded into one pass.
    private func namesDidChange() {
        guard !namesChanged, chatID != nil else { return }
        namesChanged = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.namesChanged else { return }
                self.namesChanged = false
                self.rebuild()
            }
        }
    }

    /// Measures the text rows that have no layout for `limit` yet, in the
    /// background when there are many, then installs the rows.
    private func prepare(limit: CGFloat, restyled: Bool = false) {
        generation += 1
        let generation = generation
        var missing: [TextBubbleSource] = []
        for plan in plans {
            guard case .text(_, let source) = plan else { continue }
            if let cached = textLayouts[source.id], cached.source == source, cached.layout.widthLimit == limit { continue }
            missing.append(source)
        }

        if missing.count <= backgroundThreshold {
            store(TimelineLayoutEngine.layouts(for: missing, widthLimit: limit), for: missing)
            install(limit: limit, restyled: restyled)
            return
        }
        // The table keeps showing what it has until the layouts land.
        Task {
            let layouts = await Self.measure(missing, limit: limit)
            store(layouts, for: missing)
            guard generation == self.generation else { return }
            install(limit: limit, restyled: restyled)
        }
    }

    @concurrent
    private static func measure(_ sources: [TextBubbleSource], limit: CGFloat) async -> [TextBubbleLayout] {
        let state = signposter.beginInterval("Layout", "\(sources.count) messages")
        defer { signposter.endInterval("Layout", state) }
        return TimelineLayoutEngine.layouts(for: sources, widthLimit: limit)
    }

    private func store(_ layouts: [TextBubbleLayout], for sources: [TextBubbleSource]) {
        for (source, layout) in zip(sources, layouts) {
            textLayouts[source.id] = (source, layout)
        }
    }

    /// Turns the plans into rows and applies them to the table.
    private func install(limit: CGFloat, restyled: Bool) {
        widthLimit = limit
        let width = rowWidth
        let scale = style.textScale
        let new: [Item] = plans.map { plan in
            switch plan {
            case let .chip(id, title, isDay):
                let height = chipHeights[title] ?? ChipCell.measure(title).rowHeight
                chipHeights[title] = height
                return .chip(id: id, title: title, isDay: isDay, height: height)
            case let .text(row, source):
                if let cached = textLayouts[source.id], cached.source == source, cached.layout.widthLimit == limit {
                    return .text(row, cached.layout)
                }
                let layout = TimelineLayoutEngine.layout(for: source, widthLimit: limit)
                textLayouts[source.id] = (source, layout)
                return .text(row, layout)
            case let .hosted(row):
                if let cached = hostedHeights[row.id], cached.row == row, cached.limit == limit, cached.scale == scale {
                    return .hosted(row, height: cached.height)
                }
                let height = RowMeasurer.shared.height(of: rowView(row), width: width)
                hostedHeights[row.id] = (row, limit, scale, height)
                return .hosted(row, height: height)
            }
        }
        apply(new, restyled: restyled)
        placeUnreadDivider()
        performPendingJump()
    }

    private func apply(_ new: [Item], restyled: Bool) {
        let old = items
        let follow = followsBottom
        let anchor = follow ? nil : readingAnchor()
        let diff = TimelineDiff.between(old.map(\.id), new.map(\.id)) { new[$1].differs(from: old[$0]) }
        items = new

        switch diff {
        case .none:
            // A new theme keeps every row; the SwiftUI ones draw its colours.
            if restyled, !new.isEmpty {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<new.count), columnIndexes: [0])
                refreshVisibleColors()
            }
            return
        case .reload:
            tableView.reloadData()
        case .update(let changed):
            reload(restyled ? IndexSet(integersIn: 0..<new.count) : changed, resized: IndexSet(changed.filter { old[$0].height != new[$0].height }))
        case let .patch(removed, inserted, changed):
            tableView.beginUpdates()
            if !removed.isEmpty {
                tableView.removeRows(at: removed, withAnimation: removed.count <= 3 ? .effectFade : [])
            }
            if !inserted.isEmpty {
                tableView.insertRows(at: inserted, withAnimation: [])
            }
            tableView.endUpdates()
            reload(changed, resized: changed)
        }

        if follow {
            scrollToBottom()
        } else {
            if let anchor { restore(anchor) }
            // Counted for the "newest message" button's badge.
            let known = Set(old.map(\.id))
            newBelow += new.count { item in
                guard !known.contains(item.id), let message = item.message else { return false }
                return !message.fromMe
            }
        }
    }

    /// Redraws rows that changed in place and tells the table of those
    /// whose height changed.
    private func reload(_ indexes: IndexSet, resized: IndexSet) {
        guard !indexes.isEmpty else { return }
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: [0])
        guard !resized.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: resized)
        }
    }

    // MARK: Width

    var rowWidth: CGFloat {
        let width = scrollView.contentView.bounds.width
        return width > 0 ? width : 700
    }

    private func currentWidthLimit() -> CGFloat {
        TimelineGeometry.bubbleWidthLimit(rowWidth: rowWidth)
    }

    /// Checked after the frame change, never inside the table's own layout.
    @objc private func clipResized(_ notification: Notification) {
        guard !widthCheckScheduled else { return }
        widthCheckScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.widthCheckScheduled = false
                self.checkWidth()
            }
        }
    }

    private func checkWidth() {
        let limit = currentWidthLimit()
        guard !items.isEmpty, limit != widthLimit else { return }
        if scrollView.inLiveResize {
            // Rows keep their layout during the drag; bubbles stay against
            // their edge.
            relayoutAfterLiveResize = true
        } else {
            prepare(limit: limit)
        }
    }

    private func liveResizeEnded() {
        guard relayoutAfterLiveResize else { return }
        relayoutAfterLiveResize = false
        let limit = currentWidthLimit()
        if limit != widthLimit { prepare(limit: limit) }
    }

    // MARK: Highlight and colours

    /// A search hit or quote just jumped to is marked for a moment.
    private func observeHighlight() {
        guard let model else { return }
        let key = withObservationTracking { model.highlighted } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeHighlight() }
            }
        }
        highlighted = key
        forEachTextCell { cell in
            cell.setHighlighted(isHighlighted(cell.messageID), animated: true)
        }
    }

    /// The reaction picker opens from a drawn bubble's hover control or its
    /// menu through the model, as the SwiftUI rows' popover does.
    private func observeReactionTarget() {
        guard let model else { return }
        let target = withObservationTracking { model.reactionTarget } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeReactionTarget() }
            }
        }
        reactionTarget = target
        forEachTextCell { cell in
            if let target, target.chat == chatID, target.message == cell.messageID {
                cell.showReactionPicker()
            } else {
                cell.closeReactionPicker()
            }
        }
    }

    func isHighlighted(_ id: String?) -> Bool {
        guard let highlighted, let id else { return false }
        return highlighted.chat == chatID && highlighted.message == id
    }

    private func refreshVisibleColors() {
        forEachTextCell { $0.refreshColors() }
        tableView.enumerateAvailableRowViews { rowView, _ in
            for case let cell as ChipCell in rowView.subviews { cell.refreshColors() }
        }
    }

    func forEachTextCell(_ body: (TextBubbleCell) -> Void) {
        tableView.enumerateAvailableRowViews { rowView, _ in
            for case let cell as TextBubbleCell in rowView.subviews { body(cell) }
        }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case let .chip(_, title, isDay, _):
            let cell = tableView.makeView(withIdentifier: ChipCell.identifier, owner: nil) as? ChipCell ?? ChipCell()
            cell.configure(title: title, isHeader: isDay, colors: colors)
            return cell
        case let .text(row, layout):
            let cell = tableView.makeView(withIdentifier: TextBubbleCell.identifier, owner: nil) as? TextBubbleCell
                ?? TextBubbleCell()
            cell.delegate = self
            cell.configure(id: row.id, layout: layout, highlighted: isHighlighted(row.id))
            return cell
        case .hosted(let row, _):
            // Reused only for the same kind of message, so SwiftUI updates a
            // row of the same shape instead of building another.
            let identifier = HostingCell.identifier(for: row)
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingCell
                ?? HostingCell(identifier: identifier)
            cell.show(rowView(row))
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    /// Each SwiftUI row is its own root, so what the window's environment
    /// would give it (the chat's theme, the text size, opening invite links
    /// here) is given again.
    @ViewBuilder
    func rowView(_ row: TimelineRow) -> some View {
        if let model, case let .message(message, startsRun) = row {
            MessageRow(message: message, startsRun: startsRun, isGroup: isGroup, model: model)
                .opensInviteLinks(model: model)
                .environment(\.chatTheme, style.theme)
                .environment(\.messageTextScale, style.textScale)
        }
    }

    func message(_ id: String) -> MessageRecord? {
        items.first { $0.id == id }?.message
    }
}
