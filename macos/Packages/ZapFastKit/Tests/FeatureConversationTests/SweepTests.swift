import AppKit
import Testing
import ZapFastBridge
@testable import ZapFastCore
@testable import FeatureConversation

/// Dragging across messages, through the real controller and table: the
/// events a mouse would send are scripted, and the press is handed to the
/// controller as a cell hands it.
///
/// Serialized: the scripted source of events is one for the process.
@Suite(.serialized)
@MainActor
struct SweepTests {
    private let chat = "c@s.whatsapp.net"

    private func message(_ index: Int) -> MessageRecord {
        MessageRecord(
            id: "m\(index)", chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1_780_000_000 + Int64(index) * 60, content: .text(text: "Salom \(index)", preview: nil),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Salom"
        )
    }

    private struct Fixture {
        let model: AppModel
        let controller: TimelineController
        let window: NSWindow
        let rows: [String: Int]
    }

    /// A timeline of forty incoming messages in a window out of sight.
    private func fixture() async throws -> Fixture {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-sweep-\(UUID().uuidString)")
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(data: folder, caches: folder))
        model.selectedChatID = chat
        let messages = (0..<40).map { message($0) }
        model.apply([.messages(chat: chat, messages: messages, older: false, complete: true)])
        let controller = TimelineController()
        let scroll = controller.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false
        )
        // ARC owns it: AppKit must not release it as well when it is let go.
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.update(
            chatID: chat, messages: messages, revision: 1, isGroup: false, model: model,
            style: .standard, unread: nil, jump: nil, scrollRequest: nil,
            onReachTop: {}, onScrollState: { _ in }
        )
        let deadline = Date.now.addingTimeInterval(5)
        try await Task.sleep(for: .milliseconds(50))
        while controller.items.count <= messages.count, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(controller.items.count > messages.count)
        try await Task.sleep(for: .milliseconds(50))
        controller.tableView.layoutSubtreeIfNeeded()
        let rows = Dictionary(uniqueKeysWithValues: controller.items.enumerated().map { ($1.id, $0) })
        return Fixture(model: model, controller: controller, window: window, rows: rows)
    }

    /// A point in the window: `x` across the row of `id`, halfway down it.
    private func point(_ fixture: Fixture, _ id: String, x: CGFloat = 590) -> NSPoint {
        let table = fixture.controller.tableView
        let rect = table.rect(ofRow: fixture.rows[id]!)
        return table.convert(NSPoint(x: x, y: rect.midY), to: nil)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// Presses on `id` and drags through `path`, then lets go at its end.
    /// Returns what the controller answered and the releases it put back.
    private func drag(
        _ fixture: Fixture, on id: String, from start: NSPoint, through path: [NSPoint]
    ) -> (swept: Bool, reposted: [NSEvent]) {
        var queue = path.map { event(.leftMouseDragged, at: $0, in: fixture.window) }
        queue.append(event(.leftMouseUp, at: path.last ?? start, in: fixture.window))
        var reposted: [NSEvent] = []
        let saved = TimelineController.sweepEvents
        TimelineController.sweepEvents = SweepEvents(
            next: { _, _ in queue.isEmpty ? nil : queue.removeFirst() },
            repost: { reposted.append($0) }
        )
        defer { TimelineController.sweepEvents = saved }
        let swept = fixture.controller.sweep(fromMessage: id, event: event(.leftMouseDown, at: start, in: fixture.window))
        return (swept, reposted)
    }

    /// Three rows that are on screen and clear of the edges that scroll.
    private func middle(_ fixture: Fixture) -> [String] {
        let table = fixture.controller.tableView
        let visible = table.rows(in: table.visibleRect)
        let first = visible.location + visible.length / 2 - 1
        return (first..<first + 3).map { fixture.controller.items[$0].id }
    }

    @Test func aDragDownTheSpaceBesideTheBubblesPicksEveryMessageItPasses() async throws {
        let fixture = try await fixture()
        let rows = middle(fixture)
        let result = drag(fixture, on: rows[0], from: point(fixture, rows[0]), through: rows.map { point(fixture, $0) })
        #expect(result.swept)
        #expect(fixture.model.selection?.ids == rows)
    }

    @Test func aDragBackUpLetsGoOfWhatItLeft() async throws {
        let fixture = try await fixture()
        let rows = middle(fixture)
        let path = [rows[0], rows[1], rows[2], rows[1]].map { point(fixture, $0) }
        _ = drag(fixture, on: rows[0], from: point(fixture, rows[0]), through: path)
        #expect(fixture.model.selection?.ids == [rows[0], rows[1]])
    }

    @Test func aPressThatNeverMovesStaysAClickAndItsReleaseIsPutBack() async throws {
        let fixture = try await fixture()
        let rows = middle(fixture)
        let result = drag(fixture, on: rows[1], from: point(fixture, rows[1]), through: [])
        #expect(!result.swept)
        #expect(result.reposted.map(\.type) == [.leftMouseUp])
        #expect(fixture.model.selection == nil)
        // A shake of a few points is no drag either.
        let start = point(fixture, rows[1])
        let shaken = drag(fixture, on: rows[1], from: start, through: [NSPoint(x: start.x - 2, y: start.y + 1)])
        #expect(!shaken.swept)
        #expect(fixture.model.selection == nil)
    }

    @Test func whilePickingADragFromAnywhereOnARowSweeps() async throws {
        let fixture = try await fixture()
        let rows = middle(fixture)
        fixture.model.select(fixture.controller.message(rows[0])!)
        // A press while picking has picked its row already, then the drag goes on.
        fixture.controller.toggleSelection(ofMessage: rows[1], range: false)
        let path = [rows[1], rows[2]].map { point(fixture, $0, x: 40) }
        _ = drag(fixture, on: rows[1], from: point(fixture, rows[1], x: 40), through: path)
        #expect(fixture.model.selection?.ids == rows)
        // While picking a click is the press's own work: nothing is put back.
        let click = drag(fixture, on: rows[2], from: point(fixture, rows[2], x: 40), through: [])
        #expect(click.reposted.isEmpty)
    }

    @Test func aDragFromAMessageTakenOutTakesOutWhatItPasses() async throws {
        let fixture = try await fixture()
        let rows = middle(fixture)
        fixture.model.select(fixture.controller.message(rows[0])!)
        for id in rows.dropFirst() { fixture.model.toggleSelected(fixture.controller.message(id)!) }
        #expect(fixture.model.selection?.ids == rows)
        // The press takes the middle one out; the drag takes out the one below.
        fixture.controller.toggleSelection(ofMessage: rows[1], range: false)
        _ = drag(fixture, on: rows[1], from: point(fixture, rows[1]), through: [rows[1], rows[2]].map { point(fixture, $0) })
        #expect(fixture.model.selection?.ids == [rows[0]])
    }

    @Test func theTimelineScrollsWhileThePointerIsHeldAtItsTop() async throws {
        let fixture = try await fixture()
        let rows = middle(fixture)
        let clip = fixture.controller.clip
        let before = clip.bounds.minY
        let top = fixture.controller.tableView.convert(NSPoint(x: 590, y: clip.bounds.minY + clip.contentInsets.top + 4), to: nil)
        _ = drag(fixture, on: rows[1], from: point(fixture, rows[1]), through: Array(repeating: top, count: 6))
        #expect(clip.bounds.minY < before)
        // What it scrolled past was picked on the way.
        let picked = fixture.model.selection?.ids ?? []
        #expect(picked.count > 2)
        #expect(picked.contains(rows[1]))
    }
}
