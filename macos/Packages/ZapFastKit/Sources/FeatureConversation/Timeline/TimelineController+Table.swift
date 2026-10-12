/// What the table asks the controller for: a row's width and height, the
/// highlight behind a jumped-to message, and the data source itself.

import AppKit
import Observation
import OSLog
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

extension TimelineController {
    var rowWidth: CGFloat {
        let width = scrollView.contentView.bounds.width
        return width > 0 ? width : 700
    }

    func currentWidthLimit() -> CGFloat {
        TimelineGeometry.bubbleWidthLimit(rowWidth: rowWidth)
    }

    /// Checked after the frame change, never inside the table's own layout.
    @objc func clipResized(_ notification: Notification) {
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
        widthRelayoutTask?.cancel()
        widthRelayoutTask = nil
        guard !items.isEmpty, limit != widthLimit else { return }
        if scrollView.inLiveResize {
            // Rows keep their layout during the drag; bubbles stay against
            // their edge.
            relayoutAfterLiveResize = true
        } else {
            // Split-view and programmatic window animations do not set
            // inLiveResize. Measuring the whole window for every intermediate
            // width kept all layout workers busy, only to cancel their work.
            widthRelayoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.widthRelayoutTask = nil
                let limit = self.currentWidthLimit()
                guard !self.items.isEmpty, limit != self.widthLimit else { return }
                if self.scrollView.inLiveResize { self.relayoutAfterLiveResize = true }
                else { self.prepare(limit: limit) }
            }
        }
    }

    func liveResizeEnded() {
        let scheduled = widthRelayoutTask != nil
        widthRelayoutTask?.cancel()
        widthRelayoutTask = nil
        guard relayoutAfterLiveResize || scheduled else { return }
        relayoutAfterLiveResize = false
        let limit = currentWidthLimit()
        if limit != widthLimit { prepare(limit: limit) }
    }

    // MARK: Highlight and colours

    /// A search hit or quote just jumped to is marked for a moment.
    func observeHighlight() {
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
    func observeReactionTarget() {
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

    /// The words of the chat's open search, marked in the bubbles it
    /// matched, the one on screen more strongly.
    func observeSearchMarks() {
        guard let model else { return }
        let shown = withObservationTracking { [chatID] () -> SearchShown in
            guard let search = model.search.chat, search.chat == chatID, !search.trimmedQuery.isEmpty else { return SearchShown() }
            return SearchShown(query: search.trimmedQuery, matches: Set(search.ids), current: search.currentID)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observeSearchMarks() }
            }
        }
        guard shown != searchShown else { return }
        searchShown = shown
        forEachBubbleCell { cell in
            cell.setSearchMarking(searchMarking(cell.messageID))
        }
    }

    func searchMarking(_ id: String?) -> SearchMarking? {
        guard let id, let query = searchShown.query, searchShown.matches.contains(id) else { return nil }
        return SearchMarking(query: query, current: id == searchShown.current)
    }

    func isHighlighted(_ id: String?) -> Bool {
        guard let highlighted, let id else { return false }
        return highlighted.chat == chatID && highlighted.message == id
    }

    func refreshVisibleColors() {
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
            cell.configure(
                id: row.id, layout: layout, highlighted: isHighlighted(row.id), searchMarking: searchMarking(row.id),
                mediaScope: [model?.accountID ?? "preview", chatID ?? ""]
            )
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: TimelineRowView.identifier, owner: nil) as? TimelineRowView ?? TimelineRowView()
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
