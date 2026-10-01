import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

/// One row of the sidebar's table.
enum SidebarRow {
    /// Locked Chats or Archived: opens its folder, never selected.
    case folder(id: String, title: String, systemImage: String, count: Int?, open: () -> Void)
    case chat(ChatSummary)

    var id: String {
        switch self {
        case .folder(let id, _, _, _, _): "folder-\(id)"
        case .chat(let chat): chat.id
        }
    }

    /// Whether the row shows something else than `other`.
    func differs(from other: SidebarRow) -> Bool {
        switch (self, other) {
        case let (.folder(a, _, _, countA, _), .folder(b, _, _, countB, _)): a != b || countA != countB
        case let (.chat(a), .chat(b)): a != b
        default: true
        }
    }
}

/// The sidebar's chats in an AppKit source-list table.
///
/// SwiftUI's sidebar `List` is itself a source-list outline view; this one
/// is set up with the geometry that one used (read from it at run time:
/// cells 16 points in, chat rows 56 points with the 48-point `ChatRow`
/// centred, folder rows 32). Rows are compared as values and only visible
/// rows that changed are shown again. The rows are drawn (`ChatCell`,
/// `FolderCell`) as `ChatRow` and `FolderRow` look; `ZAPFAST_SWIFTUI_ROWS=1`
/// shows those SwiftUI views instead, to compare.
final class ChatTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let scrollView = NSScrollView()
    let tableView = SidebarTableView()
    private var rows: [SidebarRow] = []
    private weak var model: AppModel?
    private var select: (String?) -> Void = { _ in }
    /// Set while the table's selection is being matched to the model's, so
    /// that change is not reported back.
    private var syncingSelection = false
    /// Rows drawn by Core Animation rather than SwiftUI views.
    var drawsRows = ProcessInfo.processInfo.environment["ZAPFAST_SWIFTUI_ROWS"] == nil

    /// `ListTableRowView` heights under SwiftUI's sidebar list.
    static let chatRowHeight: CGFloat = 56
    static let folderRowHeight: CGFloat = 32

    func makeScrollView() -> NSScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .medium
        tableView.intercellSpacing = NSSize(width: 3, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.floatsGroupRows = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.setAccessibilityLabel(String(localized: "Chats"))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        // Non-nil so the table tracks the clicked row and outlines it while
        // the menu from `menu(for:)` is open.
        tableView.menu = NSMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        return scrollView
    }

    func setTopInset(_ top: CGFloat) {
        guard scrollView.contentInsets.top != top else { return }
        let atTop = scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top + 1
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if atTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Scrolls the row of `id` into view, clear of the toolbar and search
    /// field the list runs under (`scrollRowToVisible` ignores that inset).
    func reveal(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = tableView.rect(ofRow: index)
        let clip = scrollView.contentView
        let inset = scrollView.contentInsets.top
        var y = clip.bounds.minY
        if row.minY < clip.bounds.minY + inset {
            y = row.minY - inset
        } else if row.maxY > clip.bounds.maxY {
            y = row.maxY - clip.bounds.height
        }
        guard y != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func update(rows new: [SidebarRow], selection: String?, model: AppModel, select: @escaping (String?) -> Void) {
        self.model = model
        self.select = select
        let old = rows
        rows = new

        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        if oldIDs == newIDs {
            for index in new.indices where new[index].differs(from: old[index]) {
                showAgain(index)
            }
        } else {
            let difference = newIDs.difference(from: oldIDs)
            if old.isEmpty || difference.count > 40 {
                tableView.reloadData()
            } else {
                reorder(from: old, to: new, difference)
            }
        }
        matchSelection(selection)
    }

    /// Applies a change of order as the table's own operations.
    ///
    /// At the top of the list, a chat that moves up while on screen slides
    /// there, and one from further down fades in at its place (sliding from
    /// far off would open a gap at the top). Scrolled down, nothing slides:
    /// the first chat on screen stays where it was, as the reader left it.
    private func reorder(from old: [SidebarRow], to new: [SidebarRow], _ difference: CollectionDifference<String>) {
        let atTop = isAtTop
        let anchor = atTop ? nil : visibleAnchor()
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        let animates = atTop && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        tableView.beginUpdates()
        let moved = difference.inferringMoves()
        if animates, moved.removals.count == 1, moved.insertions.count == 1,
           case .remove(let from, _, let to?) = moved.removals.first, NSLocationInRange(from, visible) {
            // One chat moved, as a new message brings it up.
            tableView.moveRow(at: from, to: to)
        } else {
            var removed = IndexSet()
            var inserted = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            tableView.removeRows(at: removed, withAnimation: [])
            tableView.insertRows(at: inserted, withAnimation: animates && inserted.count <= 3 ? .effectFade : [])
        }
        tableView.endUpdates()

        // Rows that stayed but changed.
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in new.indices {
            if let before = previous[new[index].id], new[index].differs(from: before) {
                showAgain(index)
            }
        }
        if atTop {
            scrollToTop()
        } else if let anchor {
            restore(anchor)
        }
    }

    // MARK: Scroll position

    private var isAtTop: Bool {
        scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top + 1
    }

    private func scrollToTop() {
        guard !isAtTop else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The first row on screen that is still listed, and how far below the
    /// top of the view it sits.
    private func visibleAnchor() -> (id: String, offset: CGFloat)? {
        let clip = scrollView.contentView.bounds
        let visible = tableView.rows(in: clip)
        // Called before the table hears of the change: its rows are the old ones.
        guard visible.length > 0, visible.location < tableView.numberOfRows else { return nil }
        let row = visible.location
        return (tableRowID(row), tableView.rect(ofRow: row).minY - clip.minY)
    }

    /// The id the table's row shows, read from its view.
    private func tableRowID(_ row: Int) -> String {
        switch tableView.view(atColumn: 0, row: row, makeIfNecessary: false) {
        case let cell as ChatCell: cell.chat?.id ?? ""
        case let cell as FolderCell: cell.folderID.map { "folder-\($0)" } ?? ""
        case let cell as SidebarCell: cell.rowID ?? ""
        default: ""
        }
    }

    private func restore(_ anchor: (id: String, offset: CGFloat)) {
        guard let index = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
        let top = tableView.rect(ofRow: index).minY - anchor.offset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func matchSelection(_ selection: String?) {
        let index = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        guard index != (tableView.selectedRow >= 0 ? tableView.selectedRow : nil) else { return }
        syncingSelection = true
        if let index {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        syncingSelection = false
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .folder = rows[row] { return Self.folderRowHeight }
        return Self.chatRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard drawsRows else {
            let cell = tableView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
            if let model { cell.show(rows[row], model: model) }
            return cell
        }
        switch rows[row] {
        case let .folder(id, title, systemImage, count, open):
            let cell = tableView.makeView(withIdentifier: FolderCell.identifier, owner: nil) as? FolderCell ?? FolderCell()
            cell.show(id: id, title: title, systemImage: systemImage, count: count, open: open)
            return cell
        case .chat(let chat):
            let cell = tableView.makeView(withIdentifier: ChatCell.identifier, owner: nil) as? ChatCell ?? ChatCell()
            if let model { cell.show(chat, model: model) }
            return cell
        }
    }

    /// A row on screen whose value changed shows the new one.
    private func showAgain(_ index: Int) {
        guard let model else { return }
        switch (tableView.view(atColumn: 0, row: index, makeIfNecessary: false), rows[index]) {
        case let (cell as ChatCell, .chat(chat)):
            cell.show(chat, model: model)
        case let (cell as FolderCell, .folder(id, title, systemImage, count, open)):
            cell.show(id: id, title: title, systemImage: systemImage, count: count, open: open)
        case let (cell as SidebarCell, row):
            cell.show(row, model: model)
        default:
            break
        }
    }

    /// A row that scrolled away stops following the model until reused.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for case let cell as ChatCell in rowView.subviews { cell.stopObserving() }
    }

    /// The open chat's row stays in the accent colour while the window is
    /// active, as in Messages: opening a chat moves focus to the composer,
    /// and the table would grey its selection until clicked again.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView {
            return reused
        }
        let view = SidebarRowView()
        view.identifier = SidebarRowView.identifier
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .chat = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, case .chat(let chat) = rows[row] else { return }
        select(chat.id)
    }

    /// The chat's menu, for the row right-clicked.
    func menu(forRow row: Int) -> NSMenu? {
        guard let model, rows.indices.contains(row), case .chat(let chat) = rows[row] else { return nil }
        return NSHostingMenu(rootView: ChatActions(chat: chat, model: model))
    }

    /// A click on a drawn folder row opens the folder. Returns whether it
    /// was one.
    func openFolder(atRow row: Int) -> Bool {
        guard drawsRows, rows.indices.contains(row), case .folder(_, _, _, _, let open) = rows[row] else { return false }
        open()
        return true
    }

    /// The last message in full, for the row's tooltip.
    func toolTip(forRow row: Int) -> String? {
        guard drawsRows, rows.indices.contains(row), case .chat(let chat) = rows[row] else { return nil }
        return chat.last?.full.nonEmpty
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Emphasized, in the accent colour, while its window is key.
final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarRow")
    #if DEBUG
    /// The gallery's windows are never key.
    static var emphasizesInGallery = false
    #endif

    override var isEmphasized: Bool {
        get {
            #if DEBUG
            if Self.emphasizesInGallery { return true }
            #endif
            return window?.isKeyWindow ?? false
        }
        // The table sets this when focus or the key window changes; redraw
        // with the getter's answer.
        set { super.isEmphasized = newValue }
    }
}

/// The sidebar table: its context menu is the clicked chat's, a click on a
/// folder opens it, and the row under the pointer has the tooltip, from one
/// tracking area for the table rather than one per row.
final class SidebarTableView: NSTableView, NSViewToolTipOwner {
    weak var controller: ChatTableController?
    private var tracking: NSTrackingArea?
    private var toolTipRow = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        // Lets the table note the clicked row and outline it.
        _ = super.menu(for: event)
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? controller?.menu(forRow: row) : nil
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, event.clickCount == 1, controller?.openFolder(atRow: row) == true { return }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row != toolTipRow else { return }
        toolTipRow = row
        removeAllToolTips()
        if row >= 0 { addToolTip(rect(ofRow: row), owner: self, userData: nil) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        toolTipRow = -1
        removeAllToolTips()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let row = row(at: point)
        return row >= 0 ? controller?.toolTip(forRow: row) ?? "" : ""
    }
}

/// A sidebar row's SwiftUI view in a table cell. A selected row on an
/// emphasized (active) selection gets increased background prominence,
/// as SwiftUI's list gives its selected rows, so secondary text and
/// symbols brighten on the highlight the same way.
final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarChatCell")

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var row: SidebarRow?
    private weak var model: AppModel?

    var rowID: String? { row?.id }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        host.sizingOptions = []
        // Sized by its mask, not constraints, so reusing a cell does not send
        // the window's layout pass through it.
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue, let row, let model else { return }
            show(row, model: model)
        }
    }

    func show(_ row: SidebarRow, model: AppModel) {
        self.row = row
        self.model = model
        let prominence: BackgroundProminence = backgroundStyle == .emphasized ? .increased : .standard
        host.rootView = AnyView(content(row, model: model).environment(\.backgroundProminence, prominence))
    }

    @ViewBuilder
    private func content(_ row: SidebarRow, model: AppModel) -> some View {
        switch row {
        case let .folder(_, title, systemImage, count, open):
            FolderRow(title: LocalizedStringKey(title), systemImage: systemImage, count: count, open: open)
        case .chat(let chat):
            ChatRow(chat: chat, model: model)
        }
    }
}
