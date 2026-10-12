import Foundation
import ZapFastBridge
import ZapFastCore

/// A backend with made-up history that answers like upstream's worker: a
/// chat's first page, then older pages of 60 on request, each delivered on
/// a later turn of the main queue as the bridge's pump does. Nothing leaves
/// the process and no archive is opened.
final class BenchmarkBackend: Backend {
    /// Upstream's `PAGE`.
    static let page = 60

    private var histories: [String: [MessageRecord]]
    // The real backend queries an indexed archive off the UI thread. Do
    // not charge each synthetic page or download a full main-thread scan.
    private var positions: [String: [String: Int]] = [:]
    private let media: SyntheticMedia?
    /// Chats whose first answer is their whole history.
    private let unpaged: Set<String> = [SyntheticChats.fullChat]
    private let chatCount: Int
    private var deliver: (@MainActor ([BridgeEvent]) -> Void)?

    /// Older pages answered so far.
    private(set) var pagesServed = 0

    init(fullCount: Int, pagedCount: Int, chatCount: Int, media: SyntheticMedia?) {
        histories = [
            SyntheticChats.fullChat: SyntheticChats.messages(chat: SyntheticChats.fullChat, count: fullCount, media: media),
            SyntheticChats.pagedChat: SyntheticChats.messages(chat: SyntheticChats.pagedChat, count: pagedCount, seed: 7, media: media),
            SyntheticChats.smallChat: SyntheticChats.messages(chat: SyntheticChats.smallChat, count: Self.page, seed: 9, media: media),
        ]
        self.media = media
        self.chatCount = chatCount
        positions = histories.mapValues { history in
            Dictionary(history.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func history(_ chat: String) -> [MessageRecord] {
        histories[chat] ?? []
    }

    func start(paths: AppPaths, verbose: Bool, deliver: @escaping @MainActor ([BridgeEvent]) -> Void) throws {
        self.deliver = deliver
        let newest = histories.values.compactMap(\.last?.timestamp).max() ?? 0
        post([
            .me(id: SyntheticChats.ownID, lid: nil, name: "Benchmark", about: nil),
            .chats(chats: SyntheticChats.chats(count: chatCount, newest: newest)),
            .link(state: .connected),
        ])
    }

    func send(_ command: BridgeCommand) {
        switch command {
        case let .loadMessageWindow(chat, request, query):
            let history = histories[chat] ?? []
            let range: Range<Int>
            switch query {
            case .newest: range = max(0, history.count - Self.page)..<history.count
            case .before(let message):
                let end = positions[chat]?[message] ?? 0
                range = max(0, end - Self.page)..<end
            case .after(let message):
                let start = (positions[chat]?[message] ?? -1) + 1
                range = start..<min(history.count, start + Self.page)
            case .around(let message):
                let middle = positions[chat]?[message] ?? 0
                range = max(0, middle - Self.page)..<min(history.count, middle + Self.page + 1)
            }
            pagesServed += 1
            post([.messageWindow(chat: chat, request: request, messages: Array(history[range]),
                                 hasOlder: range.lowerBound > 0, hasNewer: range.upperBound < history.count, error: nil)])
        case let .loadChat(chat, before):
            let history = histories[chat] ?? []
            let end = before.flatMap { positions[chat]?[$0.id] } ?? history.count
            let start = unpaged.contains(chat) && before == nil ? 0 : max(0, end - Self.page)
            if before != nil { pagesServed += 1 }
            post([.messages(
                chat: chat, messages: Array(history[start..<end]), older: before != nil, complete: start == 0
            )])
        case let .fetchOlder(chat):
            post([.olderFetched(chat: chat, more: false)])
        case let .download(chat, message, card):
            answerDownload(chat: chat, message: message, card: card)
        case let .sendText(chat, text, _, _):
            // Echoed a moment later, as the worker files a sent message.
            let message = SyntheticChats.message(
                chat: chat, id: "sent-\(UUID().uuidString)", sender: SyntheticChats.ownID, senderName: nil,
                fromMe: true, timestamp: nextTimestamp(in: chat), text: text
            )
            append(message, in: chat)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [deliver] in
                MainActor.assumeIsolated {
                    deliver?([.messages(chat: chat, messages: [message], older: false, complete: false)])
                }
            }
        default:
            break
        }
    }

    func shutdown() {}

    /// Someone else writes in `chat` now, as the worker delivers a live
    /// message (Debug `arrive`).
    func arrive(in chat: String, text: String) {
        let message = SyntheticChats.message(
            chat: chat, id: "arrived-\(UUID().uuidString)", sender: "998900000001@s.whatsapp.net",
            senderName: "Dilnoza", fromMe: false, timestamp: nextTimestamp(in: chat), text: text
        )
        append(message, in: chat)
        deliver?([
            .messages(chat: chat, messages: [message], older: false, complete: false),
            .incoming(chat: chat, message: message),
        ])
    }

    private func nextTimestamp(in chat: String) -> Int64 {
        max(Int64(Date().timeIntervalSince1970), (histories[chat]?.last?.timestamp ?? 0) + 1)
    }

    private func append(_ message: MessageRecord, in chat: String) {
        positions[chat, default: [:]][message.id] = histories[chat]?.count ?? 0
        histories[chat, default: []].append(message)
    }

    /// A download finishes a quarter of a second later with the made-up
    /// file of the message's kind, as the worker's `Event::Media` does.
    private func answerDownload(chat: String, message id: String, card: UInt32?) {
        guard let media, let index = positions[chat]?[id],
              let record = histories[chat]?[index] else { return }
        let path: String? = switch record.content {
        case .image: media.photos[0].path
        case .video: media.videoPath
        case .audio: media.voicePath
        case .document: media.document.path
        case .sticker: media.sticker.path
        default: nil
        }
        guard let path else { return }
        histories[chat]?[index] = Self.record(record, withFile: path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [deliver] in
            MainActor.assumeIsolated {
                deliver?([.media(chat: chat, message: id, card: card, path: path, error: nil)])
            }
        }
    }

    private static func record(_ record: MessageRecord, withFile path: String) -> MessageRecord {
        var record = record
        switch record.content {
        case .image(let caption, var media):
            media.path = path
            record.content = .image(caption: caption, media: media)
        case .video(let caption, var media, let seconds, let gif, let note):
            media.path = path
            record.content = .video(caption: caption, media: media, seconds: seconds, gif: gif, note: note)
        case .audio(var media, let seconds, let voiceNote, let waveform):
            media.path = path
            record.content = .audio(media: media, seconds: seconds, voiceNote: voiceNote, waveform: waveform)
        case .document(var media, let fileName, let caption, let pages):
            media.path = path
            record.content = .document(media: media, fileName: fileName, caption: caption, pages: pages)
        case .sticker(var media, let animated):
            media.path = path
            record.content = .sticker(media: media, animated: animated)
        default:
            break
        }
        return record
    }

    /// Delivers events at once, inside the caller's measurement.
    func inject(_ events: [BridgeEvent]) {
        deliver?(events)
    }

    /// Delivers events on a later turn of the main queue, like the pump.
    private func post(_ events: [BridgeEvent]) {
        guard let deliver else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { deliver(events) }
        }
    }
}
