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
        edited: Bool = false, forwarded: Bool = false, mentions: [MentionInfo] = [],
        quoted: QuotedMessage? = nil, reactions: [ReactionInfo] = [],
        content: MessageContent = .text(text: "hi", preview: nil)
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: nil, fromMe: fromMe,
            timestamp: time, content: content, status: .none,
            deliveredAt: nil, readAt: nil, quoted: quoted, reactions: reactions, edited: edited,
            mentions: mentions, forwarded: forwarded, thumbnail: nil, summary: ""
        )
    }

    private func media(_ path: String?, mime: String = "image/jpeg", size: UInt64 = 1) -> MediaInfo {
        MediaInfo(mime: mime, size: size, width: nil, height: nil, path: path)
    }

    private func entry(_ message: MessageRecord) -> ChatExportEntry {
        ChatExport.entry(
            for: message, me: "Me", name: { _ in "Ada" }, quotedName: { _ in "Bo" }, mentionName: { _ in "Ada" },
            locale: gb, timeZone: utc
        )
    }

    private func body(_ message: MessageRecord) -> ChatExportBody { entry(message).body }

    private func entries(_ messages: [MessageRecord], pageSize: UInt32 = 500) async throws -> [ChatExportEntry] {
        try await ChatExport.collect(
            chat: chat, reader: FakeReader(messages), me: "Me",
            name: { _ in "Ada" }, quotedName: { _ in "Bo" }, mentionName: { $0 },
            locale: gb, timeZone: utc, pageSize: pageSize
        )
    }

    // MARK: Reading

    @Test func pagesAreJoinedOldestFirstWithoutGapsOrRepeats() async throws {
        let reader = FakeReader((1...7).map { message("m\($0)", at: Int64($0)) })
        let result = try await ChatExport.collect(
            chat: chat, reader: reader, me: "Me", name: { _ in "Ada" }, quotedName: { _ in "Bo" },
            mentionName: { $0 }, locale: gb, timeZone: utc, pageSize: 3
        )
        #expect(result.map(\.timestamp) == [1, 2, 3, 4, 5, 6, 7])
        // 3 + 3 + 1: the short page says the chat has no more.
        #expect(reader.reads == 3)
    }

    @Test func aChatThatFillsItsLastPageExactlyIsReadOnePageMore() async throws {
        let reader = FakeReader((1...6).map { message("m\($0)", at: Int64($0)) })
        let result = try await ChatExport.collect(
            chat: chat, reader: reader, me: "Me", name: { _ in "Ada" }, quotedName: { _ in "Bo" },
            mentionName: { $0 }, locale: gb, timeZone: utc, pageSize: 3
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
            me: "Me", name: { _ in "Ada" }, quotedName: { _ in "Bo" }, mentionName: { $0 },
            locale: gb, timeZone: utc, pageSize: 2, progress: { seen.append($0) }
        )
        #expect(seen == [2, 4, 5])
    }

    // MARK: Words

    @Test func anEntryCarriesTheDayTheTimeAndTheAuthor() {
        let theirs = entry(message("a"))
        #expect(theirs.day == "21 September 2026")
        #expect(theirs.time == "14:13")
        #expect(theirs.author == "Ada")
        let ours = entry(message("b", fromMe: true))
        #expect(ours.author == "Me")
        #expect(ours.fromMe)
    }

    @Test func aReplyNamesWhoWasQuotedAndReactionsAreCountedPerEmoji() {
        let quote = QuotedMessage(id: "q", sender: "x", senderName: nil, summary: "Salom", mentions: [])
        let reactions = [
            ReactionInfo(sender: "a", fromMe: false, emoji: "👍"),
            ReactionInfo(sender: "b", fromMe: false, emoji: "❤️"),
            ReactionInfo(sender: "c", fromMe: false, emoji: "👍"),
        ]
        let result = entry(message("a", forwarded: true, quoted: quote, reactions: reactions))
        #expect(result.reply == ChatExportEntry.Reply(author: "Bo", summary: "Salom"))
        #expect(result.reactions == [.init(emoji: "👍", count: 2), .init(emoji: "❤️", count: 1)])
        #expect(result.forwarded)
    }

    @Test func textKeepsItsStylesLinesLinksAndNamesItsMentions() {
        let mention = MentionInfo(user: "123", id: "123@s.whatsapp.net")
        let text = message("a", mentions: [mention], content: .text(text: "*hi* @123\n_see_ https://example.org/a?b=1&c=2 ~no~", preview: nil))
        guard case .html(let html) = body(text) else { Issue.record("not html"); return }
        #expect(html.contains("<strong>hi</strong>"))
        #expect(html.contains("@Ada"))
        #expect(html.contains("<br>"))
        #expect(html.contains("<em>see</em>"))
        #expect(html.contains("<s>no</s>"))
        #expect(html.contains("<a href=\"https://example.org/a?b=1&amp;c=2\">"))
    }

    @Test func markupThatCouldRunIsOnlyText() {
        let text = message("a", content: .text(text: "<script>alert(1)</script> & \"quotes\" 'x'", preview: nil))
        guard case .html(let html) = body(text) else { Issue.record("not html"); return }
        #expect(!html.contains("<script"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot; &#39;x&#39;"))
        #expect(ChatExportHTML.safeLink(URL(string: "javascript:alert(1)")!) == nil)
        #expect(ChatExportHTML.safeLink(URL(string: "file:///etc/passwd")!) == nil)
        #expect(ChatExportHTML.safeLink(URL(string: "https://example.org")!) == "https://example.org")
        #expect(ChatExportHTML.safeLink(URL(string: "tel:+998901234567")!) == "tel:+998901234567")
    }

    @Test func attachmentsCarryTheirFileKindAndCaption() {
        let photo = message("a", content: .image(caption: "look", media: media("/cache/a.jpg", size: 9)))
        #expect(body(photo) == .media(kind: .photo, source: URL(filePath: "/cache/a.jpg"), name: nil, bytes: 9, seconds: nil, caption: "look"))

        let notYet = message("b", content: .video(caption: nil, media: media(nil), seconds: 3, gif: false, note: false))
        #expect(body(notYet) == .media(kind: .video, source: nil, name: nil, bytes: 1, seconds: 3, caption: ""))

        let note = message("c", content: .audio(media: media("/cache/c.ogg"), seconds: 41, voiceNote: true, waveform: Data()))
        #expect(body(note) == .media(kind: .voice, source: URL(filePath: "/cache/c.ogg"), name: nil, bytes: 1, seconds: 41, caption: ""))
        let song = message("d", content: .audio(media: media("/cache/d.mp3"), seconds: nil, voiceNote: false, waveform: Data()))
        #expect(body(song) == .media(kind: .audio, source: URL(filePath: "/cache/d.mp3"), name: nil, bytes: 1, seconds: nil, caption: ""))

        let document = message("e", content: .document(media: media("/cache/e.pdf", size: 5), fileName: "Report.pdf", caption: nil, pages: nil))
        #expect(body(document) == .media(kind: .document, source: URL(filePath: "/cache/e.pdf"), name: "Report.pdf", bytes: 5, seconds: nil, caption: ""))
        let sticker = message("f", content: .sticker(media: media("/cache/f.webp"), animated: false))
        #expect(body(sticker) == .media(kind: .sticker, source: URL(filePath: "/cache/f.webp"), name: nil, bytes: 1, seconds: nil, caption: ""))
        // A Lottie sticker is an animation in a zip, which a page cannot play: a file.
        let lottie = message("g", content: .sticker(media: media("/cache/g.was", mime: "application/was"), animated: true))
        #expect(body(lottie) == .media(kind: .document, source: URL(filePath: "/cache/g.was"), name: "Animated sticker.was", bytes: 1, seconds: nil, caption: ""))
    }

    @Test func placesAreLinksWithADotWhateverTheLocale() {
        let place = message("a", content: .location(latitude: 41.311081, longitude: 69.240562, name: "Registan", address: nil))
        #expect(body(place) == .html("<a href=\"https://maps.apple.com/?ll=41.311081,69.240562\">Location</a><br>\nRegistan"))
        let live = message("b", content: .liveLocation(
            latitude: 1.5, longitude: -2, accuracyM: nil, speedMps: nil, headingDeg: nil, ended: true, updated: 0
        ))
        #expect(body(live) == .html("<a href=\"https://maps.apple.com/?ll=1.500000,-2.000000\">Live location (ended)</a>"))
    }

    @Test func pollsListTheirAnswersAndVotesOnceThereAreAny() {
        #expect(ChatExport.poll("Lunch & more?", options: ["Plov", "Soup"], counts: [0, 0])
            == "<b>Lunch &amp; more?</b>\n<ul>\n<li>Plov</li>\n<li>Soup</li>\n</ul>")
        #expect(ChatExport.poll("Lunch?", options: ["Plov", "Soup"], counts: [1, 3])
            == "<b>Lunch?</b>\n<ul>\n<li>Plov <small>1 vote</small></li>\n<li>Soup <small>3 votes</small></li>\n</ul>")
    }

    @Test func whatIsGoneOrHiddenIsSaidPlainly() {
        #expect(body(message("a", content: .revoked)) == .html("<em>This message was deleted</em>"))
        #expect(body(message("b", fromMe: true, content: .revoked)) == .html("<em>You deleted this message</em>"))
        #expect(body(message("c", content: .phoneOnly(viewOnce: true, liveLocation: false, once: nil))) == .html("<em>View once message</em>"))
        #expect(body(message("d", content: .unsupported(what: "x"))) == .html("<em>This message type is not supported</em>"))
    }

    @Test func theFolderIsNamedAfterTheChatAndSafe() {
        #expect(ChatExport.suggestedFolderName(chat: "Ada") == "WhatsApp Chat - Ada")
        #expect(ChatExport.suggestedFolderName(chat: "Work/Home: A") == "WhatsApp Chat - Work-Home- A")
        #expect(ChatExport.suggestedFolderName(chat: "..") == "WhatsApp Chat - Chat")
    }

    // MARK: Pages

    private func placed(_ body: ChatExportBody, author: String = "Ada", fromMe: Bool = false, at time: Int64 = 1_790_000_000, file: String? = nil) -> ChatExportHTML.Placed {
        .init(entry: ChatExportEntry(
            id: "m\(time)", timestamp: time, day: time < 1_790_100_000 ? "21 September 2026" : "22 September 2026",
            time: "14:13", author: author, fromMe: fromMe, forwarded: false, edited: false, reply: nil, reactions: [], body: body
        ), file: file)
    }

    private func render(_ items: [ChatExportHTML.Placed], authors: Bool = true, number: Int = 1, pages: Int = 1) -> String {
        ChatExportHTML.render(.init(
            title: "Ada <&> Bo", showsAuthors: authors, number: number, pages: pages, messages: items.count,
            exported: "2 October 2026", language: "en", items: items
        ))
    }

    @Test func aPageReadsAsAConversationInSequence() {
        let html = render([
            placed(.html("one")),
            placed(.html("two"), author: "Me", fromMe: true, at: 1_790_000_030),
            placed(.html("three"), at: 1_790_200_000),
        ])
        #expect(html.contains("<title>Ada &lt;&amp;&gt; Bo</title>"))
        #expect(html.contains("3 messages, exported 2 October 2026"))
        // A heading for each day, and the days in order.
        #expect(html.components(separatedBy: "<div class=\"day\">").count - 1 == 2)
        #expect(html.range(of: "21 September 2026")!.lowerBound < html.range(of: "22 September 2026")!.lowerBound)
        // Theirs on the left, ours on the right, in the order they were sent.
        #expect(html.contains("class=\"msg in\""))
        #expect(html.contains("class=\"msg out\""))
        #expect(html.range(of: "one")!.lowerBound < html.range(of: "two")!.lowerBound)
        #expect(html.range(of: "two")!.lowerBound < html.range(of: "three")!.lowerBound)
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(!html.contains("<script"))
    }

    @Test func authorsAreNamedInAGroupOnlyAndOnlyWhenTheyChange() {
        let items = [
            placed(.html("one"), author: "Ada"),
            placed(.html("two"), author: "Ada", at: 1_790_000_010),
            placed(.html("three"), author: "Bo", at: 1_790_000_020),
            placed(.html("mine"), author: "Me", fromMe: true, at: 1_790_000_030),
        ]
        let group = render(items, authors: true)
        #expect(group.components(separatedBy: "class=\"who\"").count - 1 == 2)
        #expect(group.contains("class=\"msg in cont\""))
        #expect(!render(items, authors: false).contains("class=\"who\""))
    }

    @Test func aMissingAttachmentSaysSoAndAPresentOneIsShownByKind() {
        func media(_ kind: ChatExportMediaKind, name: String? = nil) -> ChatExportBody {
            .media(kind: kind, source: nil, name: name, bytes: 2_048, seconds: 41, caption: "")
        }
        let omitted = render([placed(media(.photo)), placed(media(.document, name: "R&D.pdf"), at: 1_790_000_100)])
        #expect(omitted.contains("Photo, not included"))
        #expect(omitted.contains("Document, not included: R&amp;D.pdf"))

        let html = render([
            placed(media(.photo), file: "photos/photo_1@a b.jpg"),
            placed(media(.sticker), file: "stickers/sticker_1.webp", ),
            placed(media(.video), file: "videos/video_1.mp4"),
            placed(media(.voice), file: "voice_messages/voice_1.ogg"),
            placed(media(.audio), file: "audio/audio_1.mp3"),
            placed(media(.document, name: "Report #1.pdf"), file: "files/Report #1.pdf"),
        ])
        #expect(html.contains("<img src=\"photos/photo_1@a%20b.jpg\""))
        #expect(html.contains("class=\"sticker\" src=\"stickers/sticker_1.webp\""))
        #expect(html.contains("<video class=\"media\" controls preload=\"metadata\" src=\"videos/video_1.mp4\">"))
        #expect(html.contains("<audio controls preload=\"none\" src=\"voice_messages/voice_1.ogg\">"))
        #expect(html.contains("<audio controls preload=\"none\" src=\"audio/audio_1.mp3\">"))
        #expect(html.contains("href=\"files/Report%20%231.pdf\""))
        #expect(html.contains("<b dir=\"auto\">Report #1.pdf</b>"))
        #expect(html.contains("0:41"))
    }

    @Test func severalPagesLinkToEachOther() {
        let middle = render([placed(.html("x"))], number: 2, pages: 3)
        #expect(middle.contains("<a href=\"messages.html\">Earlier</a>"))
        #expect(middle.contains("<a href=\"messages3.html\">Later</a>"))
        #expect(middle.contains("Page 2 of 3"))
        #expect(!render([placed(.html("x"))]).contains("<nav>"))
        #expect(ChatExportHTML.fileName(page: 1) == "messages.html")
        #expect(ChatExportHTML.fileName(page: 12) == "messages12.html")
    }

    @Test func eachPersonKeepsTheirColour() {
        #expect(ChatExportHTML.hue(of: "Ada") == ChatExportHTML.hue(of: "Ada"))
        #expect((0..<360).contains(ChatExportHTML.hue(of: "Bo")))
    }

    // MARK: File names

    @Test func attachmentsAreNumberedPerKindInTheirOwnFolder() {
        var names = ChatExportWriter.FileNames(timeZone: utc)
        let source = URL(filePath: "/cache/x.jpg")
        #expect(names.next(kind: .photo, timestamp: 1_790_000_000, source: source, original: nil)
            == "photos/photo_1@2026-09-21_14-13-20.jpg")
        #expect(names.next(kind: .photo, timestamp: 1_790_000_000, source: source, original: nil)
            == "photos/photo_2@2026-09-21_14-13-20.jpg")
        #expect(names.next(kind: .voice, timestamp: 1_790_000_000, source: URL(filePath: "/cache/v.ogg"), original: nil)
            == "voice_messages/voice_1@2026-09-21_14-13-20.ogg")
        #expect(names.next(kind: .audio, timestamp: 1_790_000_000, source: URL(filePath: "/cache/a"), original: nil)
            == "audio/audio_1@2026-09-21_14-13-20.bin")
        #expect(names.next(kind: .document, timestamp: 1, source: URL(filePath: "/cache/d.pdf"), original: "Report.pdf")
            == "files/Report.pdf")
        #expect(names.next(kind: .document, timestamp: 2, source: URL(filePath: "/cache/d2.pdf"), original: "report.PDF")
            == "files/report (2).PDF")
    }

    @Test func aDocumentNameThatCouldEscapeTheFolderIsNotUsed() {
        #expect(ChatExportWriter.FileNames.documentName("..") == nil)
        #expect(ChatExportWriter.FileNames.documentName("a/b:c.txt") == "a-b-c.txt")
        #expect(ChatExportWriter.FileNames.documentName(String(repeating: "x", count: 300)) == nil)
        var names = ChatExportWriter.FileNames(timeZone: utc)
        let file = names.next(kind: .document, timestamp: 1_790_000_000, source: URL(filePath: "/cache/d.pdf"), original: "..")
        #expect(file == "files/file_1@2026-09-21_14-13-20.pdf")
    }

    // MARK: Files

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func listing(_ folder: URL) throws -> [String] {
        let files = FileManager.default
        let names = try files.subpathsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        return names.filter { !((try? files.contentsOfDirectory(atPath: folder.appending(path: $0).path(percentEncoded: false))) != nil) }
    }

    private func write(
        _ entries: [ChatExportEntry], media: Bool, into parent: URL, pageSize: Int = 1000
    ) async throws -> ChatExportSummary {
        try await ChatExportWriter.write(
            entries, title: "Ada", showsAuthors: true, includeMedia: media, into: parent,
            locale: gb, timeZone: utc, now: Date(timeIntervalSince1970: 1_790_000_000), pageSize: pageSize
        )
    }

    private func item(_ body: ChatExportBody, at time: Int64 = 1_790_000_000) -> ChatExportEntry {
        placed(body, at: time).entry
    }

    @Test func withMediaTheFolderHoldsThePagesAndEachFileInItsKindsFolder() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let photo = source.appending(path: "p.jpg"), voice = source.appending(path: "v.ogg"), pdf = source.appending(path: "d.pdf")
        for file in [photo, voice, pdf] { try Data([1, 2, 3]).write(to: file) }
        let parent = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let summary = try await write([
            item(.media(kind: .photo, source: photo, name: nil, bytes: 3, seconds: nil, caption: "look")),
            item(.media(kind: .voice, source: voice, name: nil, bytes: 3, seconds: 4, caption: ""), at: 1_790_000_060),
            item(.media(kind: .document, source: pdf, name: "Report.pdf", bytes: 3, seconds: nil, caption: ""), at: 1_790_000_120),
            item(.media(kind: .photo, source: nil, name: nil, bytes: 3, seconds: nil, caption: ""), at: 1_790_000_180),
            item(.media(kind: .audio, source: source.appending(path: "gone.mp3"), name: nil, bytes: 3, seconds: nil, caption: ""), at: 1_790_000_240),
            item(.html("done"), at: 1_790_000_300),
        ], media: true, into: parent)

        #expect(summary.folder.lastPathComponent == "WhatsApp Chat - Ada")
        #expect(summary.page.lastPathComponent == "messages.html")
        #expect(summary.attachments == 3)
        // One never downloaded, one whose file is gone.
        #expect(summary.missingMedia == 2)
        #expect(try listing(summary.folder) == [
            "files/Report.pdf", "messages.html",
            "photos/photo_1@2026-09-21_14-13-20.jpg", "voice_messages/voice_1@2026-09-21_14-14-20.ogg",
        ])
        let html = try String(contentsOf: summary.page, encoding: .utf8)
        #expect(html.contains("src=\"photos/photo_1@2026-09-21_14-13-20.jpg\""))
        #expect(html.contains("src=\"voice_messages/voice_1@2026-09-21_14-14-20.ogg\""))
        #expect(html.contains("href=\"files/Report.pdf\""))
        #expect(html.contains("Photo, not included"))
        #expect(html.contains("Audio, not included"))
        #expect(html.contains("look"))
        #expect(try Data(contentsOf: summary.folder.appending(path: "photos/photo_1@2026-09-21_14-13-20.jpg")) == Data([1, 2, 3]))
    }

    @Test func withoutMediaThereAreNoFilesAndTheConversationStillReads() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appending(path: "p.jpg")
        try Data([1]).write(to: photo)
        let summary = try await write([
            item(.html("hello")),
            item(.media(kind: .photo, source: photo, name: nil, bytes: 1, seconds: nil, caption: "look"), at: 1_790_000_060),
        ], media: false, into: root)
        #expect(try listing(summary.folder) == ["messages.html"])
        #expect(summary.attachments == 0 && summary.missingMedia == 0)
        let html = try String(contentsOf: summary.page, encoding: .utf8)
        #expect(html.contains("hello") && html.contains("Photo, not included") && html.contains("look"))
    }

    @Test func aLongChatIsSplitIntoPagesThatLinkToEachOther() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = (0..<5).map { item(.html("message \($0)"), at: 1_790_000_000 + Int64($0)) }
        let summary = try await write(all, media: false, into: root, pageSize: 2)
        #expect(try listing(summary.folder) == ["messages.html", "messages2.html", "messages3.html"])
        let first = try String(contentsOf: summary.page, encoding: .utf8)
        let last = try String(contentsOf: summary.folder.appending(path: "messages3.html"), encoding: .utf8)
        #expect(first.contains("message 0") && first.contains("message 1") && !first.contains("message 2"))
        #expect(first.contains("messages2.html") && !first.contains("Earlier"))
        #expect(last.contains("message 4") && last.contains("Earlier") && !last.contains("Later"))
        #expect(first.contains("5 messages"))
    }

    @Test func anEmptyChatStillMakesAPage() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = try await write([], media: true, into: root)
        #expect(try listing(summary.folder) == ["messages.html"])
        #expect(summary.messages == 0)
    }

    @Test func anExportNeverReplacesOneThatIsThere() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await write([item(.html("first"))], media: false, into: root)
        let second = try await write([item(.html("second"))], media: false, into: root)
        let third = try await write([item(.html("third"))], media: false, into: root)
        #expect([first, second, third].map { $0.folder.lastPathComponent }
            == ["WhatsApp Chat - Ada", "WhatsApp Chat - Ada 2", "WhatsApp Chat - Ada 3"])
        #expect(try String(contentsOf: first.page, encoding: .utf8).contains("first"))
    }

    @Test func aFailedExportLeavesNoFolderBehind() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [item(.html("one")), item(.html("two"), at: 1_790_000_060)]
        let task = Task {
            // Cancelled before it starts, as a person closing the app would.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.write(entries, media: true, into: root)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).isEmpty)
    }

    @Test func aFolderThatCannotBeMadeIsAnError() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await write([item(.html("x"))], media: false, into: root.appending(path: "no/such/place"))
        }
    }

    // MARK: Through the model

    @Test func theModelExportsOneChatAtATimeAndReportsWhereItWent() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ExportBackend(FakeReader([message("a", at: 1_790_000_000), message("b", at: 1_790_000_060, fromMe: true)]))
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let parent = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        model.requestExport(chat)
        #expect(model.exportRequest == ChatExportRequest(chat: chat))

        let done = await withCheckedContinuation { continuation in
            model.exportChat(chat, includeMedia: false, into: parent) { continuation.resume(returning: $0) }
            #expect(model.exportingChat == chat)
            #expect(model.exportRequest == nil)
        }
        let summary = try done.get()
        #expect(summary.messages == 2)
        #expect(model.exportingChat == nil)
        #expect(model.notices.last?.text == "Exported 2 messages")
        let html = try String(contentsOf: summary.page, encoding: .utf8)
        #expect(html.contains(">hi<") && html.contains("class=\"msg out\""))
    }

    @Test func aBackendWithoutAnArchiveFailsPlainly() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        let result = await withCheckedContinuation { continuation in
            model.exportChat(chat, includeMedia: false, into: root) { continuation.resume(returning: $0) }
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
