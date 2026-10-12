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

    let scrollView = HoverScrollView()
    let tableView = TimelineTableView()
    var chatID: String?
    var revision: Int?
    var messages: MessageHistory = []
    var isGroup = false
    var style = TimelineStyle.standard
    var colors = BubbleColors(TimelineStyle.standard)
    /// The day of the messages at the top of the view, over the timeline
    /// while it is scrolled by hand, and for a moment after.
    let floatingDay = ChipCell()
    var floatingTitle: String?
    var floatingHide: Task<Void, Never>?
    var unread: UnreadDivider?
    /// The chat's calls, shown among the messages of their time.
    var calls: [CallLogEntry] = []
    /// The messages reach the chat's start, so older calls show too.
    var fromStart = false
    /// `ZAPFAST_SWIFTUI_ROWS=1` shows every message as the earlier SwiftUI
    /// row, to compare the two, in the app or the benchmark.
    var drawsBubbles = ProcessInfo.processInfo.environment["ZAPFAST_SWIFTUI_ROWS"] == nil
    weak var model: AppModel?
    var onReachTop: () -> Void = {}
    var onReachBottom: () -> Void = {}
    var onWantNewest: () -> Void = {}
    var onReadingAnchor: (String?, Bool) -> Void = { _, _ in }
    var hasNewer = false
    var reachBottomScheduled = false
    /// What a sender's page asks of the window (a dialog, a sheet).
    var onInfoRequest: (InfoRequest) -> Void = { _ in }
    /// The page of the person whose name or photo was clicked.
    var senderPopover: NSPopover?
    /// The message whose menu is open, marked, with the reactions above it.
    var messageMenu: MessageMenuSession?
    var onScrollState: (ScrollState) -> Void = { _ in }

    var items: [Item] = []
    /// Where each item is, for cells asking about their message; kept with
    /// `items` by `setItems`, and by the changes that keep or add to them.
    var itemIndex: [String: Int] = [:]
    var plans: [Plan] = []
    /// The bubble width the items are laid out for.
    var widthLimit: CGFloat = 0

    var bubbleLayouts: [String: (source: BubbleSource, layout: BubbleLayout)] = [:]
    var hostedHeights: [String: (row: TimelineRow, limit: CGFloat, scale: Double, height: CGFloat)] = [:]
    var chipHeights: [String: CGFloat] = [:]
    /// Bumped by every preparation; a background layout that finishes after
    /// a newer one started is not installed.
    var generation = 0
    let measurementOwner = UUID()
    var layoutTask: Task<Void, Never>?
    var layoutCancellation = TimelineLayoutCancellation()
    var measureLayouts: @Sendable ([BubbleSource], CGFloat, UUID, TimelineLayoutCancellation) async -> [BubbleLayout] = {
        await TimelineLayoutScheduler.shared.measure($0, limit: $1, owner: $2, cancellation: $3)
    }
    /// Layouts are being measured in the background; the rows on screen
    /// are older than the plans.
    var preparing = false

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
    var highlighted: MessageKey?
    /// The open search's words and matches, which bubbles mark.
    var searchShown = SearchShown()
    var reactionTarget: MessageKey?
    var namesChanged = false
    var widthCheckScheduled = false
    var reachTopScheduled = false
    var relayoutAfterLiveResize = false
    var observers: [NSObjectProtocol] = []

    /// Within this distance of an edge counts as being at it.
    let edgeSlack: CGFloat = 48
    /// Older pages are requested this far before the top is reached.
    let prefetchDistance: CGFloat = 600
    /// More new text rows than this are measured in the background: a live
    /// message or two is laid out at once, a page of history off the main
    /// actor (60 messages took about 12 ms there, mostly link detection).
    let backgroundThreshold = 8

    nonisolated static let signposter = OSSignposter(subsystem: "ZapFast", category: "Timeline")

    /// AppKit's scroll edge effect under the title bar washes the top of
    /// the chat in the window's colour, over the wallpaper; the pane's own
    /// band (`TitleBandView`) frosts that edge in the wallpaper's colour
    /// instead. The switch is not published (macOS 26 offers styles, not
    /// "none"): where it is missing, AppKit's effect stays.
    private static func dropTopEdgeEffect(_ scrollView: NSScrollView) {
        let getter = NSSelectorFromString("allowedPocketEdges")
        let setter = NSSelectorFromString("setAllowedPocketEdges:")
        guard scrollView.responds(to: getter), scrollView.responds(to: setter) else { return }
        typealias Get = @convention(c) (AnyObject, Selector) -> UInt
        typealias Set = @convention(c) (AnyObject, Selector, UInt) -> Void
        let allowed = unsafeBitCast(scrollView.method(for: getter), to: Get.self)(scrollView, getter)
        // Edge 0 is the top, a bit per edge.
        unsafeBitCast(scrollView.method(for: setter), to: Set.self)(scrollView, setter, allowed & ~UInt(1))
    }

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
        // Content scrolls under the title bar and the composer; `place` insets
        // it by both, and keeps the scroll bar clear of them.
        scrollView.automaticallyAdjustsContentInsets = false
        Self.dropTopEdgeEffect(scrollView)

        floatingDay.passesPointer = true
        floatingDay.large = true
        floatingDay.alphaValue = 0
        scrollView.addSubview(floatingDay)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrolled), name: NSScrollView.didLiveScrollNotification, object: scrollView
        )

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
        layoutCancellation.cancel()
        layoutTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        NotificationCenter.default.removeObserver(self)
    }

}

/// What the open search asks the timeline to mark.
struct SearchShown: Equatable {
    var query: String?
    var matches: Set<String> = []
    var current: String?
}

/// The words to mark in one bubble, and whether it is the match on screen.
struct SearchMarking: Equatable {
    let query: String
    let current: Bool
}
