#if DEBUG
import Foundation
import ZapFastBridge

extension PhoneFetch {
    /// A made-up chat with a made-up job at some stage, for looking at the
    /// sheet without a linked account: `ready`, `files`, `paused`, `done`,
    /// `history` or `historyend`. Nothing here touches a real archive.
    public static func demo(stage: String) async -> (fetch: PhoneFetch, model: AppModel) {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-fetch-demo")
        let model = AppModel(
            backend: PreviewBackend(),
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: "zapfast-fetch-demo")!)
        )
        model.session.link = .connected
        let kinds: [(ChatMediaKind, UInt64)] = [
            (.photo, 180_000), (.photo, 220_000), (.voice, 30_000), (.document, 2_400_000), (.audio, 3_900_000),
            (.video, 12_000_000), (.photo, 190_000), (.voice, 41_000),
        ]
        let media = (0..<40).map { index -> ChatMedia in
            let (kind, size) = kinds[index % kinds.count]
            return ChatMedia(message: "m\(index)", timestamp: 1_790_000_000 - Int64(index) * 3600, kind: kind, size: size, here: index % 7 == 0)
        }
        let reader = DemoReader(ChatCensus(messages: 1240, oldest: 1_772_000_000, media: media))
        let fetch = PhoneFetch(chat: "demo@s.whatsapp.net", hooks: .init(
            openReader: { reader }, download: { _ in }, askOlder: {}, isConnected: { true },
            gone: GoneMedia(defaults: UserDefaults(suiteName: "zapfast-fetch-demo")!)
        ))
        while fetch.phase == .counting { try? await Task.sleep(for: .milliseconds(10)) }
        let missing = media.filter { !$0.here }.map(\.message)
        switch stage {
        case "files":
            fetch.startFiles()
            for id in missing.prefix(11) { fetch.fileFinished(message: id, error: nil) }
            fetch.fileFinished(message: missing[11], error: "No longer available on WhatsApp's servers")
        case "paused":
            fetch.startFiles()
            for id in missing.prefix(5) { fetch.fileFinished(message: id, error: "Your phone did not answer. Open WhatsApp on it and try again") }
            fetch.fileFinished(message: missing[5], error: nil)
        case "done":
            fetch.startFiles()
            for (index, id) in missing.enumerated() {
                let error = index % 6 == 5 ? "No longer available on WhatsApp's servers" : nil
                fetch.fileFinished(message: id, error: error)
            }
        case "history":
            fetch.startHistory()
            fetch.olderArrived(count: 150)
            fetch.olderAnswered(more: true)
        case "historyend":
            fetch.startHistory()
            fetch.olderArrived(count: 100)
            fetch.olderAnswered(more: false)
        default:
            break
        }
        return (fetch, model)
    }
}

private final class DemoReader: ChatReaderProtocol, @unchecked Sendable {
    func message(chat: String, id: String) throws -> MessageRecord? { nil }
    func selectedIds(chat: String, ids: [String]) throws -> [String] { [] }
    let census: ChatCensus
    init(_ census: ChatCensus) { self.census = census }
    func census(chat: String) throws -> ChatCensus { census }
    func page(chat: String, before: PageKey?, limit: UInt32) throws -> [MessageRecord] { [] }
}
#endif
