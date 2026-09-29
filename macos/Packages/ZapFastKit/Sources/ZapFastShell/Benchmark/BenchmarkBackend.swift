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

    private let histories: [String: [MessageRecord]]
    /// Chats whose first answer is their whole history.
    private let unpaged: Set<String> = [SyntheticChats.fullChat]
    private let chatCount: Int
    private var deliver: (@MainActor ([BridgeEvent]) -> Void)?

    /// Older pages answered so far.
    private(set) var pagesServed = 0

    init(fullCount: Int, pagedCount: Int, chatCount: Int) {
        histories = [
            SyntheticChats.fullChat: SyntheticChats.messages(chat: SyntheticChats.fullChat, count: fullCount),
            SyntheticChats.pagedChat: SyntheticChats.messages(chat: SyntheticChats.pagedChat, count: pagedCount, seed: 7),
            SyntheticChats.smallChat: SyntheticChats.messages(chat: SyntheticChats.smallChat, count: Self.page, seed: 9),
        ]
        self.chatCount = chatCount
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
        case let .loadChat(chat, before):
            let history = histories[chat] ?? []
            let end = before.flatMap { key in history.firstIndex { $0.id == key.id } } ?? history.count
            let start = unpaged.contains(chat) && before == nil ? 0 : max(0, end - Self.page)
            if before != nil { pagesServed += 1 }
            post([.messages(
                chat: chat, messages: Array(history[start..<end]), older: before != nil, complete: start == 0
            )])
        case let .fetchOlder(chat):
            post([.olderFetched(chat: chat, more: false)])
        default:
            break
        }
    }

    func shutdown() {}

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
