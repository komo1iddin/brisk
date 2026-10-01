import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastSharedUI

/// One row of the sidebar's table.
enum SidebarRow {
    /// Locked Chats or Archived: opens its folder, never selected.
    case folder(id: String, title: LocalizedStringKey, systemImage: String, count: Int?, open: () -> Void)
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
/// centred, folder rows 32), and shows the same `ChatRow` and `FolderRow`.
/// What changes is who diffs the rows: the list rebuilt and compared every
/// row's view for each message anywhere, a few milliseconds per message
/// with 200 chats; here the rows are compared as values and only visible
/// rows that changed are handed a new view.
struct ChatTable: NSViewRepresentable {
    let rows: [SidebarRow]
    @Binding var selection: String?
    let model: AppModel
    /// The toolbar and search field above: the list runs under them, as
    /// SwiftUI's did, with its content inset by this much.
    var topInset: CGFloat = 0

    func makeCoordinator() -> ChatTableController {
        ChatTableController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    /// Whatever it is offered, so rows the table adds while scrolling do
    /// not send the window through SwiftUI layout again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 400))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let binding = $selection
        context.coordinator.setTopInset(topInset)
        context.coordinator.update(rows: rows, selection: selection, model: model) { binding.wrappedValue = $0 }
    }
}

final class ChatTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let scrollView = NSScrollView()
    private let tableView = SidebarTableView()
    private var rows: [SidebarRow] = []
    private weak var model: AppModel?
    private var select: (String?) -> Void = { _ in }
    /// Set while the table's selection is being matched to the model's, so
    /// that change is not reported back.
    private var syncingSelection = false

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
                (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCell)?.show(new[index], model: model)
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
        if let model {
            for index in new.indices {
                if let before = previous[new[index].id], new[index].differs(from: before) {
                    (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCell)?.show(new[index], model: model)
                }
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
        (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.rowID ?? ""
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
        let cell = tableView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
        if let model { cell.show(rows[row], model: model) }
        return cell
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
}

/// Emphasized, in the accent colour, while its window is key.
final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarRow")

    override var isEmphasized: Bool {
        get { window?.isKeyWindow ?? false }
        // The table sets this when focus or the key window changes; redraw
        // with the getter's answer.
        set { super.isEmphasized = newValue }
    }
}

/// The sidebar table: its context menu is the clicked chat's.
final class SidebarTableView: NSTableView {
    weak var controller: ChatTableController?

    override func menu(for event: NSEvent) -> NSMenu? {
        // Lets the table note the clicked row and outline it.
        _ = super.menu(for: event)
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? controller?.menu(forRow: row) : nil
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
            FolderRow(title: title, systemImage: systemImage, count: count, open: open)
        case .chat(let chat):
            ChatRow(chat: chat, model: model)
        }
    }
}
