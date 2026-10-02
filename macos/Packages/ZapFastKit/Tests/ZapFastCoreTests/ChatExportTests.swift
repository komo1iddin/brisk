import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

/// Pages of a chat the way the archive serves them: the newest ones first,
/// then older ones from a boundary message.
private final class FakeReader: ChatReaderProtocol, @unchecked Sendable {
    private let messages: [MessageRecord]
    private(set) var reads = 0

    init(_ messages: [MessageRecord]) { self.messages = messages }

    func page(chat: String, before: PageKey?, limit: UInt32) throws -> [MessageRecord] {
        reads += 1
        let end = before.flatMap { key in messages.firstIndex { $0.id == key.id } } ?? messages.count
        return Array(messages[max(0, end - Int(limit))..<end])
    }
}

@MainActor
struct ChatExportTests {
    private let chat = "c@s.whatsapp.net"
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    private func message(
        _ id: String, at time: Int64 = 1_790_000_000, fromMe: Bool = false,
        edited: Bool = false, mentions: [MentionInfo] = [],
        content: MessageContent = .text(text: "hi", preview: nil)
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: fromMe,
            timestamp: time, content: content, status: .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: edited,
            mentions: mentions, forwarded: false, thumbnail: nil, summary: ""
        )
    }

    private func media(_ path: String?, mime: String = "image/jpeg") -> MediaInfo {
        MediaInfo(mime: mime, size: 1, width: nil, height: nil, path: path)
    }

    private func body(_ message: MessageRecord) -> ChatExportBody {
        ChatExport.body(of: message, mentionName: { _ in "Ada" })
    }

    private func entries(_ messages: [MessageRecord], pageSize: UInt32 = 500) async throws -> [ChatExportEntry] {
        try await ChatExport.collect(
            chat: chat, reader: FakeReader(messages), me: "Me",
            name: { _ in "Ada" }, mentionName: { $0 },
            locale: gb, timeZone: utc, pageSize: pageSize
        )
    }

    // MARK: Reading

    @Test func pagesAreJoinedOldestFirstWithoutGapsOrRepeats() async throws {
        let all = (1...7).map { message("m\($0)", at: Int64($0)) }
        let reader = FakeReader(all)
        let result = try await ChatExport.collect(
            chat: chat, reader: reader, me: "Me", name: { _ in "Ada" }, mentionName: { $0 },
            locale: gb, timeZone: utc, pageSize: 3
        )
        #expect(result.map(\.timestamp) == [1, 2, 3, 4, 5, 6, 7])
        // 3 + 3 + 1: the short page says the chat has no more.
        #expect(reader.reads == 3)
    }

    @Test func aChatThatFillsItsLastPageExactlyIsReadOnePageMore() async throws {
        let reader = FakeReader((1...6).map { message("m\($0)", at: Int64($0)) })
        let result = try await ChatExport.collect(
            chat: chat, reader: reader, me: "Me", name: { _ in "Ada" }, mentionName: { $0 },
            locale: gb, timeZone: utc, pageSize: 3
        )
        #expect(result.count == 6)
        #expect(reader.reads == 3)
    }

    @Test func anEmptyChatExportsNothing() async throws {
        #expect(try await entries([]).isEmpty)
    }

    @Test func progressCountsWhatWasRead() async throws {
        var seen: [Int] = []
        _ = try await ChatExport.collect(
            chat: chat, reader: FakeReader((1...5).map { message("m\($0)", at: Int64($0)) }),
            me: "Me", name: { _ in "Ada" }, mentionName: { $0 },
            locale: gb, timeZone: utc, pageSize: 2, progress: { seen.append($0) }
        )
        #expect(seen == [2, 4, 5])
    }

    // MARK: Words

    @Test func theLineStartsWithTheTimeAndTheAuthor() async throws {
        let result = try await entries([message("a"), message("b", fromMe: true)])
        #expect(result[0].stamp == "21/09/2026, 14:13:20")
        #expect(result[0].author == "Ada")
        #expect(result[1].author == "Me")
    }

    @Test func textKeepsItsLinesAndNamesItsMentions() {
        let mention = MentionInfo(user: "123", id: "123@s.whatsapp.net")
        let one = message("a", mentions: [mention], content: .text(text: "hi @123\nbye", preview: nil))
        #expect(body(one) == .text("hi @Ada\nbye"))
    }

    @Test func anEditedMessageSaysSo() {
        #expect(body(message("a", edited: true)) == .text("hi <This message was edited>"))
    }

    @Test func attachmentsCarryTheirFileAndCaption() {
        let photo = message("a", content: .image(caption: "look", media: media("/cache/a.jpg")))
        #expect(body(photo) == .media(kind: .photo, source: URL(filePath: "/cache/a.jpg"), name: nil, caption: "look"))

        let notYet = message("b", content: .video(caption: nil, media: media(nil), seconds: 3, gif: false, note: false))
        #expect(body(notYet) == .media(kind: .video, source: nil, name: nil, caption: ""))

        let document = message("c", content: .document(media: media("/cache/c.pdf"), fileName: "Report.pdf", caption: nil, pages: nil))
        #expect(body(document) == .media(kind: .document, source: URL(filePath: "/cache/c.pdf"), name: "Report.pdf", caption: ""))
    }

    @Test func placesAreLinksWithADotWhateverTheLocale() {
        let place = message("a", content: .location(latitude: 41.311081, longitude: 69.240562, name: "Registan", address: nil))
        #expect(body(place) == .text("location: https://maps.apple.com/?ll=41.311081,69.240562\nRegistan"))

        let live = message("b", content: .liveLocation(
            latitude: 1.5, longitude: -2, accuracyM: nil, speedMps: nil, headingDeg: nil, ended: true, updated: 0
        ))
        #expect(body(live) == .text("live location: https://maps.apple.com/?ll=1.500000,-2.000000 (ended)"))
    }

    @Test func pollsListTheirAnswersAndVotesOnceThereAreAny() {
        #expect(ChatExport.poll("Lunch?", options: ["Plov", "Soup"], counts: [0, 0])
            == "POLL:\nLunch?\nOPTION: Plov\nOPTION: Soup")
        #expect(ChatExport.poll("Lunch?", options: ["Plov", "Soup"], counts: [1, 3])
            == "POLL:\nLunch?\nOPTION: Plov (1 vote)\nOPTION: Soup (3 votes)")
    }

    @Test func whatIsGoneOrHiddenIsSaidPlainly() {
        #expect(body(message("a", content: .revoked)) == .text("This message was deleted"))
        #expect(body(message("b", fromMe: true, content: .revoked)) == .text("You deleted this message"))
        #expect(body(message("c", content: .phoneOnly(viewOnce: true, liveLocation: false, once: nil))) == .text("<View once message>"))
        #expect(body(message("d", content: .unsupported(what: "x"))) == .text("<This message type is not supported>"))
    }

    @Test func theSuggestedNameIsThePhonesAndSafe() {
        #expect(ChatExport.suggestedFileName(chat: "Ada", withMedia: false) == "WhatsApp Chat - Ada.txt")
        #expect(ChatExport.suggestedFileName(chat: "Work/Home: A", withMedia: true) == "WhatsApp Chat - Work-Home- A.zip")
        #expect(ChatExport.suggestedFileName(chat: "..", withMedia: true) == "WhatsApp Chat - Chat.zip")
    }

    // MARK: File names

    @Test func attachmentsAreNumberedInOrderAndDocumentsKeepTheirNames() {
        var names = ChatExportWriter.FileNames(timeZone: utc)
        let source = URL(filePath: "/cache/x.jpg")
        #expect(names.next(kind: .photo, timestamp: 1_790_000_000, source: source, original: nil)
            == "00000001-PHOTO-2026-09-21-14-13-20.jpg")
        #expect(names.next(kind: .document, timestamp: 1, source: URL(filePath: "/cache/d.pdf"), original: "Report.pdf")
            == "Report.pdf")
        #expect(names.next(kind: .document, timestamp: 2, source: URL(filePath: "/cache/d2.pdf"), original: "report.PDF")
            == "report (2).PDF")
        #expect(names.next(kind: .audio, timestamp: 1_790_000_000, source: URL(filePath: "/cache/v"), original: nil)
            == "00000004-AUDIO-2026-09-21-14-13-20.bin")
    }

    @Test func aDocumentNameThatCouldEscapeTheFolderIsNotUsed() {
        #expect(ChatExportWriter.FileNames.documentName("..") == nil)
        #expect(ChatExportWriter.FileNames.documentName("a/b:c.txt") == "a-b-c.txt")
        #expect(ChatExportWriter.FileNames.documentName(String(repeating: "x", count: 300)) == nil)
        var names = ChatExportWriter.FileNames(timeZone: utc)
        let file = names.next(kind: .document, timestamp: 1_790_000_000, source: URL(filePath: "/cache/d.pdf"), original: "..")
        #expect(file == "00000001-DOCUMENT-2026-09-21-14-13-20.pdf")
    }

    // MARK: Files

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func entry(_ body: ChatExportBody, author: String = "Ada", at time: Int64 = 1_790_000_000) -> ChatExportEntry {
        ChatExportEntry(timestamp: time, stamp: "21/09/2026, 14:13:20", author: author, body: body)
    }

    @Test func withoutMediaTheTextStandsAloneAndNamesNoFiles() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "p.jpg")
        try Data([1]).write(to: photo)
        let destination = folder.appending(path: "chat.txt")

        let summary = try await ChatExportWriter.write(
            [entry(.text("hello\nthere")), entry(.media(kind: .photo, source: photo, name: nil, caption: "look"), author: "Me")],
            includeMedia: false, to: destination, timeZone: utc
        )

        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text == "[21/09/2026, 14:13:20] Ada: hello\nthere\n[21/09/2026, 14:13:20] Me: <Media omitted>\nlook\n")
        #expect(summary == ChatExportSummary(url: destination, messages: 2, attachments: 0, missingMedia: 0))
    }

    @Test func withMediaTheZipHoldsTheTextAndEachDownloadedFile() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appending(path: "p.jpg")
        try Data([1, 2, 3]).write(to: photo)
        let destination = folder.appending(path: "chat.zip")

        let summary = try await ChatExportWriter.write(
            [
                entry(.media(kind: .photo, source: photo, name: nil, caption: "look")),
                entry(.media(kind: .photo, source: nil, name: nil, caption: "")),
                entry(.media(kind: .audio, source: folder.appending(path: "gone.opus"), name: nil, caption: "")),
                entry(.text("done")),
            ],
            includeMedia: true, to: destination, timeZone: utc
        )
        #expect(summary.attachments == 1)
        // One never downloaded, one whose file is gone.
        #expect(summary.missingMedia == 2)

        let unpacked = folder.appending(path: "unpacked")
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", destination.path(percentEncoded: false), unpacked.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        let names = try FileManager.default.contentsOfDirectory(atPath: unpacked.path(percentEncoded: false)).sorted()
        #expect(names == ["00000001-PHOTO-2026-09-21-14-13-20.jpg", "_chat.txt"])
        let text = try String(contentsOf: unpacked.appending(path: "_chat.txt"), encoding: .utf8)
        #expect(text.hasPrefix("[21/09/2026, 14:13:20] Ada: <attached: 00000001-PHOTO-2026-09-21-14-13-20.jpg>\nlook\n"))
        #expect(text.hasSuffix("Ada: done\n"))
        #expect(try Data(contentsOf: unpacked.appending(path: names[0])) == Data([1, 2, 3]))
    }

    @Test func anExistingFileIsReplaced() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "chat.zip")
        try Data("old".utf8).write(to: destination)
        _ = try await ChatExportWriter.write([entry(.text("new"))], includeMedia: true, to: destination, timeZone: utc)
        #expect(try Data(contentsOf: destination) != Data("old".utf8))
    }

    // MARK: Through the model

    @Test func theModelExportsOneChatAtATimeAndReportsWhereItWent() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = ExportBackend(FakeReader([message("a", at: 1_790_000_000), message("b", at: 1_790_000_060, fromMe: true)]))
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: folder, caches: folder),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let destination = folder.appending(path: "chat.txt")

        model.requestExport(chat)
        #expect(model.exportRequest == ChatExportRequest(chat: chat))

        let done = await withCheckedContinuation { continuation in
            model.exportChat(chat, includeMedia: false, to: destination) { continuation.resume(returning: $0) }
            #expect(model.exportingChat == chat)
            #expect(model.exportRequest == nil)
        }
        let summary = try done.get()
        #expect(summary.messages == 2)
        #expect(model.exportingChat == nil)
        #expect(model.notices.last?.text == "Exported 2 messages")
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text.contains("You: hi") && text.hasSuffix("\n"))
    }

    @Test func aBackendWithoutAnArchiveFailsPlainly() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: folder, caches: folder),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let result = await withCheckedContinuation { continuation in
            model.exportChat(chat, includeMedia: false, to: folder.appending(path: "x.txt")) {
                continuation.resume(returning: $0)
            }
        }
        #expect((try? result.get()) == nil)
        #expect(model.exportingChat == nil)
        #expect(model.notices.last?.kind == .error)
    }
}

/// A backend whose archive is a fixed chat.
private final class ExportBackend: Backend {
    private let reader: FakeReader
    init(_ reader: FakeReader) { self.reader = reader }

    func start(paths: AppPaths, verbose: Bool, deliver: @escaping @MainActor ([BridgeEvent]) -> Void) throws {}
    func send(_ command: BridgeCommand) {}
    func openChatReader() async throws -> any ChatReaderProtocol { reader }
    func shutdown() {}
}
