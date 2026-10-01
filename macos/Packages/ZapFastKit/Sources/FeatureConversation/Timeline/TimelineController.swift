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
///   (`TimelineLayoutEngine`) and drawn by Core Animation (`BubbleCell`);
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
        case bubble(TimelineRow, BubbleSource)
        case hosted(TimelineRow)
    }

    enum Item {
        case chip(id: String, title: String, isDay: Bool, height: CGFloat)
        case bubble(TimelineRow, BubbleLayout)
        case hosted(TimelineRow, height: CGFloat)

        var id: String {
            switch self {
            case .chip(let id, _, _, _): id
            case .bubble(let row, _), .hosted(let row, _): row.id
            }
        }

        var height: CGFloat {
            switch self {
            case .chip(_, _, _, let height), .hosted(_, let height): height
            case .bubble(_, let layout): layout.rowHeight
            }
        }

        var message: MessageRecord? {
            if case .message(let message, _, _)? = row { message } else { nil }
        }

        var row: TimelineRow? {
            switch self {
            case .chip: nil
            case .bubble(let row, _), .hosted(let row, _): row
            }
        }

        func differs(from other: Item) -> Bool {
            switch (self, other) {
            case let (.chip(_, a, _, _), .chip(_, b, _, _)): a != b
            case let (.bubble(_, a), .bubble(_, b)): a !== b
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
    /// `ZAPFAST_SWIFTUI_ROWS=1` shows every message as the earlier SwiftUI
    /// row, to compare the two, in the app or the benchmark.
    var drawsBubbles = ProcessInfo.processInfo.environment["ZAPFAST_SWIFTUI_ROWS"] == nil
    weak var model: AppModel?
    var onReachTop: () -> Void = {}
    var onScrollState: (ScrollState) -> Void = { _ in }

    private(set) var items: [Item] = []
    /// Where each item is, for cells asking about their message; kept with
    /// `items` by `setItems`, and by the changes that keep or add to them.
    private var itemIndex: [String: Int] = [:]
    private var plans: [Plan] = []
    /// The bubble width the items are laid out for.
    private var widthLimit: CGFloat = 0

    private var bubbleLayouts: [String: (source: BubbleSource, layout: BubbleLayout)] = [:]
    private var hostedHeights: [String: (row: TimelineRow, limit: CGFloat, scale: Double, height: CGFloat)] = [:]
    private var chipHeights: [String: CGFloat] = [:]
    /// Bumped by every preparation; a background layout that finishes after
    /// a newer one started is not installed.
    private(set) var generation = 0
    /// Layouts are being measured in the background; the rows on screen
    /// are older than the plans.
    private var preparing = false

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
            setItems([])
            // Layouts and heights stay, keyed by message: going back to a
            // chat read a moment ago measures nothing again. Only their
            // number is bounded.
            if bubbleLayouts.count > 8_000 { bubbleLayouts = [:] }
            if hostedHeights.count > 3_000 { hostedHeights = [:] }
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
        // Anything that regroups or restyles the rows makes them all again.
        // Picking messages does not: each row shows its checkbox itself.
        var rebuilds = restyled || unread != self.unread
        if restyled {
            self.style = style
            colors = BubbleColors(style)
        }
        self.unread = unread
        if revision != self.revision {
            self.revision = revision
            let old = self.messages
            self.messages = messages
            // A download, a receipt, a reaction or an edit changes a message
            // or two in place: those rows alone are made again, not all of
            // them, which cost a frame or more in a long chat each time. A
            // message that arrives adds its own rows after the others.
            if !rebuilds, let edited = editedInPlace(from: old, to: messages) {
                refresh(edited)
            } else if !rebuilds, let change = appended(from: old, to: messages) {
                refresh(change.edited)
                append(change.arrived, after: change.last)
            } else {
                rebuilds = true
            }
        }
        if rebuilds {
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

    /// The messages that changed between two lists of the same messages in
    /// the same order, or nil when they differ otherwise (messages came,
    /// went, or moved; or a change could regroup the rows: a sender or a
    /// time). At most a few dozen; more is a new list.
    private func editedInPlace(from old: [MessageRecord], to new: [MessageRecord]) -> [MessageRecord]? {
        guard !items.isEmpty, !preparing, old.count == new.count, !new.isEmpty else { return nil }
        return changed(from: old, to: new[...])
    }

    /// The messages that arrived after the last one, the last one before
    /// them, and the earlier messages that changed in place (a receipt for
    /// the reader's own message often comes with the answer); nil when the
    /// list changed otherwise, or so much that it is a new list.
    private func appended(
        from old: [MessageRecord], to new: [MessageRecord]
    ) -> (edited: [MessageRecord], arrived: ArraySlice<MessageRecord>, last: MessageRecord)? {
        guard !items.isEmpty, !preparing, let last = old.last, new.count > old.count,
              new.count - old.count <= backgroundThreshold,
              let edited = changed(from: old, to: new[..<old.count]) else { return nil }
        let arrived = new[old.count...]
        // Rows group by what came before, so later messages only add rows.
        guard arrived.allSatisfy({ $0.timestamp >= last.timestamp }) else { return nil }
        return (edited, arrived, last)
    }

    /// The messages of `new` that differ from those of `old` at the same
    /// place, when nothing that groups the rows (an id, a sender, a time)
    /// changed and at most a few dozen did.
    private func changed(from old: [MessageRecord], to new: ArraySlice<MessageRecord>) -> [MessageRecord]? {
        var edited: [MessageRecord] = []
        // By index: zipping copied every message out of both lists.
        for index in old.indices where old[index] != new[new.startIndex + index] {
            let after = new[new.startIndex + index]
            guard old[index].id == after.id, old[index].timestamp == after.timestamp, old[index].sender == after.sender,
                  old[index].fromMe == after.fromMe, edited.count < 48 else { return nil }
            edited.append(after)
        }
        return edited
    }

    /// Adds the rows of messages that arrived after `last`: their day and
    /// the unread divider if they start one, then the messages themselves,
    /// measured here (they are a few). The rows above are left alone, and
    /// the list is added to in place rather than compared with a new one:
    /// in a long chat that copying and comparing was most of a message's
    /// cost.
    private func append(_ arrived: ArraySlice<MessageRecord>, after last: MessageRecord) {
        let rows = TimelineRow.build([last] + arrived, unread: unread)
        guard let lastRow = rows.firstIndex(where: { $0.id == last.id }) else {
            rebuild()
            return
        }
        // The last message ends its run no more when the first to arrive
        // continues it: its row loses the sender's photo and the tail.
        if case let .message(_, _, endsRun) = rows[lastRow], let index = itemIndex[last.id],
           case let .message(message, startsRun, ended)? = items[index].row, ended != endsRun {
            refresh(rows: [(index, .message(message, startsRun: startsRun, endsRun: endsRun))])
        }
        let resolved = resolve(Array(rows[(lastRow + 1)...]))
        let limit = widthLimit > 0 ? widthLimit : currentWidthLimit()
        let added = resolved.map { item(for: $0, limit: limit) }
        guard !added.isEmpty, added.allSatisfy({ itemIndex[$0.id] == nil }) else {
            rebuild()
            return
        }
        let follow = followsBottom
        let anchor = follow ? nil : readingAnchor()
        let start = items.count
        plans += resolved
        items += added
        for (offset, item) in added.enumerated() { itemIndex[item.id] = start + offset }
        tableView.insertRows(at: IndexSet(integersIn: start..<items.count), withAnimation: [])
        if follow {
            scrollToBottom()
        } else {
            if let anchor { restore(anchor) }
            // Counted for the "newest message" button's badge.
            newBelow += added.count { $0.message.map { !$0.fromMe } ?? false }
        }
    }

    private func setItems(_ new: [Item]) {
        items = new
        itemIndex = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Makes the rows of `edited` again, where they are, and tells the table
    /// of those that changed; the reader stays where they were.
    private func refresh(_ edited: [MessageRecord]) {
        var rows: [(index: Int, row: TimelineRow)] = []
        // Messages whose picture changed (a document's page preview came):
        // the quotes of them show it too.
        var pictured = Set<String>()
        for message in edited {
            guard let index = itemIndex[message.id], case let .message(old, startsRun, endsRun)? = items[index].row else { continue }
            if old.thumbnail != message.thumbnail { pictured.insert(message.id) }
            rows.append((index, .message(message, startsRun: startsRun, endsRun: endsRun)))
        }
        if !pictured.isEmpty {
            let edited = Set(edited.map(\.id))
            for index in items.indices {
                guard case let .message(message, startsRun, endsRun)? = items[index].row,
                      let quoted = message.quoted?.id, pictured.contains(quoted), !edited.contains(message.id) else { continue }
                rows.append((index, .message(message, startsRun: startsRun, endsRun: endsRun)))
            }
        }
        refresh(rows: rows)
    }

    /// Makes these rows again, in place.
    private func refresh(rows: [(index: Int, row: TimelineRow)]) {
        guard !rows.isEmpty else { return }
        let limit = widthLimit > 0 ? widthLimit : currentWidthLimit()
        let resolved = resolve(rows.map(\.row))
        let follow = followsBottom
        let anchor = follow ? nil : readingAnchor()
        var changed = IndexSet()
        var resized = IndexSet()
        var updated = items
        for ((index, _), plan) in zip(rows, resolved) {
            plans[index] = plan
            let item = self.item(for: plan, limit: limit)
            guard item.differs(from: updated[index]) else { continue }
            changed.insert(index)
            if item.height != updated[index].height { resized.insert(index) }
            updated[index] = item
        }
        guard !changed.isEmpty else { return }
        // The same rows in the same places: the index holds.
        items = updated
        reload(changed, resized: resized)
        if follow {
            scrollToBottom()
        } else if let anchor, !resized.isEmpty {
            restore(anchor)
        }
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
        let swiftUIRows = !drawsBubbles
        let chat = chatID
        // Quoted messages among those loaded: where each is, indexed the
        // first time a quote asks.
        let messages = messages
        var positions: [String: Int]?
        func original(_ id: String) -> MessageRecord? {
            if positions == nil {
                var index = [String: Int](minimumCapacity: messages.count)
                for position in messages.indices { index[messages[position].id] = position }
                positions = index
            }
            return positions?[id].map { messages[$0] }
        }
        return withObservationTracking {
            rows.map { row -> Plan in
                switch row {
                case let .day(id, title):
                    return .chip(id: id, title: title, isDay: true)
                case .unread(let count):
                    let title = String(AttributedString(localized: "^[\(count) unread message](inflect: true)").characters)
                    return .chip(id: row.id, title: title, isDay: false)
                case let .message(message, startsRun, endsRun):
                    guard !swiftUIRows, let source = BubbleSource.make(
                        message, startsRun: startsRun, endsRun: endsRun, isGroup: isGroup, colors: colors, chats: model.chats,
                        voiceAvatars: model.preferences.voiceAvatars,
                        senderPhones: model.preferences.senderPhones,
                        playingVoice: { model.voice.current.flatMap { $0.chat == chat ? $0.message : nil } },
                        own: model.session.account.map { ($0.id, $0.name ?? "") },
                        original: original
                    ) else { return .hosted(row) }
                    return .bubble(row, source)
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
        var missing: [BubbleSource] = []
        for plan in plans {
            guard case .bubble(_, let source) = plan else { continue }
            if let cached = bubbleLayouts[source.id], cached.source == source, cached.layout.widthLimit == limit { continue }
            missing.append(source)
        }

        if missing.count <= backgroundThreshold {
            // Whatever was measuring in the background is older now.
            preparing = false
            store(TimelineLayoutEngine.layouts(for: missing, widthLimit: limit), for: missing)
            install(limit: limit, restyled: restyled)
            return
        }
        // The table keeps showing what it has until the layouts land.
        preparing = true
        Task {
            let layouts = await Self.measure(missing, limit: limit)
            store(layouts, for: missing)
            guard generation == self.generation else { return }
            preparing = false
            install(limit: limit, restyled: restyled)
        }
    }

    @concurrent
    private static func measure(_ sources: [BubbleSource], limit: CGFloat) async -> [BubbleLayout] {
        let state = signposter.beginInterval("Layout", "\(sources.count) messages")
        defer { signposter.endInterval("Layout", state) }
        return TimelineLayoutEngine.layouts(for: sources, widthLimit: limit)
    }

    private func store(_ layouts: [BubbleLayout], for sources: [BubbleSource]) {
        for (source, layout) in zip(sources, layouts) {
            bubbleLayouts[source.id] = (source, layout)
        }
    }

    /// Turns the plans into rows and applies them to the table.
    private func install(limit: CGFloat, restyled: Bool) {
        widthLimit = limit
        let new: [Item] = plans.map { item(for: $0, limit: limit) }
        apply(new, restyled: restyled)
        placeUnreadDivider()
        performPendingJump()
    }

    /// A plan measured: from the caches when it was measured before.
    private func item(for plan: Plan, limit: CGFloat) -> Item {
        switch plan {
        case let .chip(id, title, isDay):
            let height = chipHeights[title] ?? ChipCell.measure(title).rowHeight
            chipHeights[title] = height
            return .chip(id: id, title: title, isDay: isDay, height: height)
        case let .bubble(row, source):
            if let cached = bubbleLayouts[source.id], cached.source == source, cached.layout.widthLimit == limit {
                return .bubble(row, cached.layout)
            }
            let layout = TimelineLayoutEngine.layout(for: source, widthLimit: limit)
            bubbleLayouts[source.id] = (source, layout)
            return .bubble(row, layout)
        case let .hosted(row):
            let scale = style.textScale
            if let cached = hostedHeights[row.id], cached.row == row, cached.limit == limit, cached.scale == scale {
                return .hosted(row, height: cached.height)
            }
            let height = RowMeasurer.shared.height(of: rowView(row), width: rowWidth)
            hostedHeights[row.id] = (row, limit, scale, height)
            return .hosted(row, height: height)
        }
    }

    private func apply(_ new: [Item], restyled: Bool) {
        let old = items
        let follow = followsBottom
        let anchor = follow ? nil : readingAnchor()
        let diff = TimelineDiff.between(old.map(\.id), new.map(\.id)) { new[$1].differs(from: old[$0]) }
        setItems(new)

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
        forEachBubbleCell { cell in
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
        forEachBubbleCell { cell in
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
        forEachBubbleCell { $0.refreshColors() }
        tableView.enumerateAvailableRowViews { rowView, _ in
            for case let cell as ChipCell in rowView.subviews { cell.refreshColors() }
        }
    }

    func forEachBubbleCell(_ body: (BubbleCell) -> Void) {
        tableView.enumerateAvailableRowViews { rowView, _ in
            for case let cell as BubbleCell in rowView.subviews { body(cell) }
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
        case let .bubble(row, layout):
            let identifier = BubbleCell.identifier(for: layout)
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? BubbleCell
                ?? BubbleCell(identifier: identifier)
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

    /// A row that scrolled away stops what plays in it.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for case let cell as BubbleCell in rowView.subviews { cell.leftScreen() }
    }

    /// Each SwiftUI row is its own root, so what the window's environment
    /// would give it (the chat's theme, the text size, opening invite links
    /// here) is given again.
    @ViewBuilder
    func rowView(_ row: TimelineRow) -> some View {
        if let model, case let .message(message, startsRun, endsRun) = row {
            MessageRow(message: message, startsRun: startsRun, endsRun: endsRun, isGroup: isGroup, model: model)
                .opensInviteLinks(model: model)
                .environment(\.chatTheme, style.theme)
                .environment(\.messageTextScale, style.textScale)
        }
    }

    func message(_ id: String) -> MessageRecord? {
        itemIndex[id].map { items[$0] }?.message
    }
}
