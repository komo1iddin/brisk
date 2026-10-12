import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

private final class SelectionReader: ChatReaderProtocol, @unchecked Sendable {
    let rows: [MessageRecord]
    init(_ rows: [MessageRecord]) { self.rows = rows }
    func page(chat: String, before: PageKey?, limit: UInt32) throws -> [MessageRecord] {
        let boundary = before.flatMap { key in rows.firstIndex { $0.chat == chat && $0.id == key.id } } ?? rows.count
        return Array(rows[..<boundary].filter { $0.chat == chat }.suffix(Int(limit)))
    }
    func census(chat: String) throws -> ChatCensus { ChatCensus(messages: UInt64(rows.count), oldest: nil, media: []) }
    func message(chat: String, id: String) throws -> MessageRecord? { rows.first { $0.chat == chat && $0.id == id } }
    func selectedIds(chat: String, ids: [String]) throws -> [String] { rows.filter { $0.chat == chat && ids.contains($0.id) }.map(\.id) }
}

@MainActor
struct WindowSelectionTests {
    private final class ArchiveBackend: Backend {
        let reader: SelectionReader
        init(_ rows: [MessageRecord]) { reader = SelectionReader(rows) }
        func start(paths: AppPaths, verbose: Bool, deliver: @escaping @MainActor ([BridgeEvent]) -> Void) throws {}
        func send(_ command: BridgeCommand) {}
        func shutdown() {}
        func openChatReader() async throws -> any ChatReaderProtocol { reader }
    }
    private func rows(_ range: Range<Int>) -> [MessageRecord] {
        range.map { index in
            MessageRecord(id: "m\(index)", chat: "fixture", sender: "sender", senderName: "Synthetic",
                          fromMe: false, timestamp: Int64(index), content: .text(text: "Fixture \(index)", preview: nil),
                          status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
                          mentions: [], forwarded: false, thumbnail: nil, summary: "")
        }
    }
    private func fixture() -> (AppModel, TimelineReader) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-window-selection-\(UUID())")
        let model = AppModel(backend: ArchiveBackend(rows(0..<200)), paths: AppPaths(data: folder, caches: folder),
                             preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        model.apply(.messages(chat: "fixture", messages: rows(100..<160), older: false, complete: false))
        let reader = model.openTimelineReader("fixture")
        reader.store.applyWindow(chat: "fixture", messages: rows(0..<60), query: .around(message: "m20"), hasOlder: false, hasNewer: true)
        return (model, reader)
    }

    @Test func selectingAnOlderPaneUsesItsOrderAndCopiesItsMessages() {
        let (model, _) = fixture()
        model.select(rows(20..<21)[0])
        model.selectRange(to: rows(22..<23)[0])
        #expect(model.selection?.ids == ["m20", "m21", "m22"])
        #expect(model.forwardableSelection.count == 3)
        var copied = ""
        model.copySelection { copied = $0 }
        #expect(copied.contains("Fixture 20") && copied.contains("Fixture 21") && copied.contains("Fixture 22"))
        #expect(model.selection == nil && model.selectionMetadata.isEmpty)
    }

    @Test func copyAndShareHydrateEvictedSelectionsWithoutRetainingRecords() async throws {
        let (model, reader) = fixture()
        model.select(rows(20..<21)[0])
        model.selectRange(to: rows(22..<23)[0])
        reader.store.applyWindow(chat: "fixture", messages: rows(100..<160), query: .newest, hasOlder: true, hasNewer: false)
        #expect(model.selectionNeedsArchive)
        #expect(model.selectionMetadata["m20"]?.forwardable == true)
        let share = try #require(await model.archivedSelectionShare())
        #expect(share.text?.contains("Fixture 20") == true)
        var copied = ""
        model.copySelection { copied = $0 }
        let deadline = ContinuousClock.now + .seconds(2)
        while copied.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(copied.contains("Fixture 22"))
        #expect(model.selection == nil)
    }

    @Test func evictedForwardSelectionUsesArchiveOrder() async throws {
        let (model, reader) = fixture()
        model.select(rows(22..<23)[0])
        model.toggleSelected(rows(20..<21)[0])
        reader.store.applyWindow(chat: "fixture", messages: rows(100..<160), query: .newest, hasOlder: true, hasNewer: false)
        model.forwardSelection()
        let deadline = ContinuousClock.now + .seconds(2)
        while model.forwarding == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.forwarding?.messages == ["m20", "m22"])
        #expect(model.selection == nil)
    }

    @Test func archivedShareKeepsSingleTextFormattingAlongsideMedia() async throws {
        var records = rows(20..<22)
        records[1].content = .audio(media: .init(mime: "audio/ogg", size: 1, width: nil, height: nil, path: "/tmp/synthetic.ogg"),
                                    seconds: 1, voiceNote: true, waveform: Data())
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-share-format-\(UUID())")
        let model = AppModel(backend: ArchiveBackend(records), paths: AppPaths(data: folder, caches: folder),
                             preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        model.apply(.messages(chat: "fixture", messages: records, older: false, complete: true))
        model.select(records[0])
        model.toggleSelected(records[1])
        let loaded = model.shareableSelection
        model.conversations.applyWindow(chat: "fixture", messages: rows(100..<160), query: .newest, hasOlder: true, hasNewer: false)
        #expect(model.selectionNeedsArchive)
        let archived = try #require(await model.archivedSelectionShare())
        #expect(archived == loaded)
        #expect(archived.text == "Fixture 20")
    }

    @Test func aCancelledSelectionCannotPublishAnAsyncCopy() async throws {
        let (model, reader) = fixture()
        model.select(rows(20..<21)[0])
        reader.store.applyWindow(chat: "fixture", messages: rows(100..<160), query: .newest, hasOlder: true, hasNewer: false)
        var copied = false
        model.copySelection { _ in copied = true }
        model.cancelSelection()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!copied)
    }

    @Test func shiftClickExtendsAcrossAnEvictedAnchorAndWholeArchivePages() async throws {
        let (model, reader) = fixture()
        model.select(rows(20..<21)[0])
        reader.store.applyWindow(chat: "fixture", messages: rows(100..<160), query: .newest, hasOlder: true, hasNewer: false)
        model.selectRange(to: rows(105..<106)[0])
        let deadline = ContinuousClock.now + .seconds(2)
        while model.selectionRangeRequest != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.selection?.ids == (20...105).map { "m\($0)" })
        #expect(reader.conversation.messages.count == 60)
        #expect(model.selectionMetadata["m75"]?.forwardable == true)
    }

    @Test func latestArchivedRangeWinsAndCancellationKeepsItRetired() async throws {
        let (model, reader) = fixture()
        model.select(rows(20..<21)[0])
        reader.store.applyWindow(chat: "fixture", messages: rows(100..<160), query: .newest, hasOlder: true, hasNewer: false)
        model.selectRange(to: rows(105..<106)[0])
        model.selectRange(to: rows(110..<111)[0])
        let deadline = ContinuousClock.now + .seconds(2)
        while model.selectionRangeRequest != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.selection?.ids == (20...110).map { "m\($0)" })
        model.selectRange(to: rows(130..<131)[0])
        model.cancelSelection()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.selection == nil && model.selectionMetadata.isEmpty)
    }
}
