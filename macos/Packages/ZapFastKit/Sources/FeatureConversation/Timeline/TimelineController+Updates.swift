/// Taking a new list of messages and showing it: what changed, what is
/// inserted or removed, and what the table is told about it.

import AppKit
import Observation
import OSLog
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

extension TimelineController {
    func update(
        chatID: String,
        messages: some Collection<MessageRecord>,
        revision: Int,
        changes: [ConversationDelta] = [],
        calls: [CallLogEntry] = [],
        fromStart: Bool = false,
        isGroup: Bool,
        model: AppModel,
        style: TimelineStyle,
        unread: UnreadDivider?,
        jump: JumpRequest?,
        scrollRequest: TimelineScrollRequest?,
        onReachTop: @escaping () -> Void,
        onScrollState: @escaping (ScrollState) -> Void
    ) {
        let messages = MessageHistory(messages)
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
            senderPopover?.close()
            hideFloatingDay(immediately: true)
            setItems([])
            // Layouts and heights stay, keyed by message: going back to a
            // chat read a moment ago measures nothing again. Only their
            // number is bounded.
            if bubbleLayouts.count > 8_000 { bubbleLayouts = [:] }
            if hostedHeights.count > 3_000 { hostedHeights = [:] }
            generation += 1
            layoutCancellation.cancel()
            layoutTask?.cancel()
            followsBottom = true
            placesUnread = true
            newBelow = 0
            handledScroll = scrollRequest?.token
            tableView.reloadData()
            observeSearchMarks()
        }
        if let jump, jump.key.chat == chatID, jump.token != handledJump {
            pendingJump = jump
        }
        let restyled = style != self.style
        // Anything that regroups or restyles the rows makes them all again.
        // Picking messages does not: each row shows its checkbox itself.
        var rebuilds = restyled || unread != self.unread || calls != self.calls
            || (fromStart != self.fromStart && !calls.isEmpty)
        self.calls = calls
        self.fromStart = fromStart
        if restyled {
            self.style = style
            colors = BubbleColors(style)
            floatingTitle = nil
        }
        self.unread = unread
        if revision != self.revision {
            let previousRevision = self.revision
            self.revision = revision
            let old = self.messages
            self.messages = messages
            // A download, a receipt, a reaction or an edit changes a message
            // or two in place: those rows alone are made again, not all of
            // them, which cost a frame or more in a long chat each time. A
            // message that arrives adds its own rows after the others.
            if !rebuilds, !items.isEmpty, !preparing, let previousRevision,
               let delta = TimelineMutation.resolve(changes, after: previousRevision, through: revision,
                                                    previousCount: old.count, count: messages.count),
               messages.count - old.count <= backgroundThreshold {
                refresh(delta.filter { $0 < old.count }.map { messages[$0] })
                if messages.count > old.count, let last = old.last { append(messages[old.count...], after: last) }
            } else if !rebuilds, let edited = editedInPlace(from: old, to: messages) {
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
    private func editedInPlace(from old: MessageHistory, to new: MessageHistory) -> [MessageRecord]? {
        guard !items.isEmpty, !preparing, old.count == new.count, !new.isEmpty else { return nil }
        return changed(from: old, to: new[...])
    }

    /// The messages that arrived after the last one, the last one before
    /// them, and the earlier messages that changed in place (a receipt for
    /// the reader's own message often comes with the answer); nil when the
    /// list changed otherwise, or so much that it is a new list.
    private func appended(
        from old: MessageHistory, to new: MessageHistory
    ) -> (edited: [MessageRecord], arrived: Slice<MessageHistory>, last: MessageRecord)? {
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
    private func changed(from old: MessageHistory, to new: Slice<MessageHistory>) -> [MessageRecord]? {
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
    func append(_ arrived: Slice<MessageHistory>, after last: MessageRecord) {
        let rows = TimelineRow.build([last] + Array(arrived), unread: unread)
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
        let before = clip.bounds.minY
        plans += resolved
        items += added
        for (offset, item) in added.enumerated() { itemIndex[item.id] = start + offset }
        tableView.insertRows(at: IndexSet(integersIn: start..<items.count), withAnimation: [])
        if follow {
            scrollToBottom()
            animateArrival(rows: start..<items.count, shift: clip.bounds.minY - before)
        } else {
            if let anchor { restore(anchor) }
            // Counted for the "newest message" button's badge.
            newBelow += added.count { $0.message.map { !$0.fromMe } ?? false }
        }
    }

    func setItems(_ new: [Item]) {
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
        for ((index, _), plan) in zip(rows, resolved) {
            plans[index] = plan
            let item = self.item(for: plan, limit: limit)
            guard item.differs(from: items[index]) else { continue }
            changed.insert(index)
            if item.height != items[index].height { resized.insert(index) }
            // The main actor owns this array. Keeping a second value here
            // copied and retained every row for a one-message refresh.
            items[index] = item
        }
        guard !changed.isEmpty else { return }
        // The same rows in the same places: the index holds.
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
        let rows = TimelineRow.build(messages, calls: calls, fromStart: fromStart, unread: unread)
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
                case .call(let entry):
                    return .chip(id: row.id, title: CallText.title(entry), isDay: false)
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
    func prepare(limit: CGFloat, restyled: Bool = false) {
        layoutCancellation.cancel()
        layoutTask?.cancel()
        layoutTask = nil
        layoutCancellation = TimelineLayoutCancellation()
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
        let cancellation = layoutCancellation
        let owner = measurementOwner
        let measure = measureLayouts
        layoutTask = Task { [weak self] in
            let layouts = await Self.measure(missing, limit: limit, owner: owner, cancellation: cancellation, measure: measure)
            guard !Task.isCancelled, !cancellation.isCancelled,
                  let self, generation == self.generation, layouts.count == missing.count else { return }
            self.store(layouts, for: missing)
            self.preparing = false
            self.layoutTask = nil
            self.install(limit: limit, restyled: restyled)
        }
    }

    @concurrent
    static func measure(_ sources: [BubbleSource], limit: CGFloat, owner: UUID, cancellation: TimelineLayoutCancellation,
                        measure: @Sendable ([BubbleSource], CGFloat, UUID, TimelineLayoutCancellation) async -> [BubbleLayout]) async -> [BubbleLayout] {
        let state = signposter.beginInterval("Layout", "\(sources.count) messages")
        defer { signposter.endInterval("Layout", state) }
        return await measure(sources, limit, owner, cancellation)
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
    func item(for plan: Plan, limit: CGFloat) -> Item {
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
            newBelow += TimelineArrivals.count(from: old, to: new)
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
}
