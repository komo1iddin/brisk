import Foundation
import ZapFastBridge

struct SelectionMetadata {
    let order: MessageOrder
    let forwardable: Bool
}

extension AppModel {
    /// Shift-click may start at a row already evicted from the pane. Read
    /// that explicit range in pages, retaining only selection metadata.
    func extendArchivedSelection(_ chosen: MessageSelection, to message: MessageRecord) {
        guard canSelect(message) else { return }
        let request = UUID()
        selectionRangeRequest = request
        Task { [weak self] in
            guard let self else { return }
            defer { if selectionRangeRequest == request { selectionRangeRequest = nil } }
            @MainActor func current() -> Bool { selection == chosen && selectionRangeRequest == request && !appLock.isLocked }
            do {
                let reader = try await backend.openChatReader()
                let endpoints = try await Self.orderedSelection(reader, chat: chosen.chat, ids: [chosen.anchor, message.id])
                guard current(), endpoints.count == 2,
                      let upper = try await Self.selectedRecord(reader, chat: chosen.chat, id: endpoints[1]) else { return }
                var metadata: [String: SelectionMetadata] = [:]
                @MainActor func retain(_ record: MessageRecord) {
                    if canSelect(record) {
                        metadata[record.id] = SelectionMetadata(order: record.order, forwardable: canForward(record))
                    }
                }
                retain(upper)
                var boundary = PageKey(timestamp: upper.timestamp, id: upper.id)
                var found = false
                while !found {
                    guard current() else { return }
                    let page = try await Self.selectionPage(reader, chat: chosen.chat, before: boundary)
                    guard current(), let first = page.first else { return }
                    for record in page.reversed() {
                        retain(record)
                        if record.id == endpoints[0] { found = true; break }
                    }
                    boundary = PageKey(timestamp: first.timestamp, id: first.id)
                }
                let ids = try await Self.orderedSelection(reader, chat: chosen.chat, ids: Array(Set(chosen.ids).union(metadata.keys)))
                guard current() else { return }
                selectionMetadata.merge(metadata, uniquingKeysWith: { _, new in new })
                selection = MessageSelection(chat: chosen.chat, ids: ids, anchor: message.id)
            } catch {
                if current() { post(.error, String(localized: "Could not read the selected messages")) }
            }
        }
    }

    func captureSelection(_ messages: some Sequence<MessageRecord>) {
        for message in messages where canSelect(message) {
            selectionMetadata[message.id] = SelectionMetadata(order: message.order, forwardable: canForward(message))
        }
    }

    func actionMessages(in chat: String, containing id: String? = nil) -> MessageHistory {
        if let selectionReader, let reader = timelineReaders[selectionReader], reader.chat == chat,
           id == nil || reader.store.loadedMessage(chat: chat, id: id!) != nil {
            return reader.conversation.messages
        }
        if let id, let reader = timelineReaders.values.first(where: { $0.chat == chat && $0.conversation.message(id) != nil }) {
            return reader.conversation.messages
        }
        return conversations.conversation(chat).messages
    }

    public var selectionNeedsArchive: Bool {
        guard let selection else { return false }
        return selection.ids.contains { loadedMessage(chat: selection.chat, id: $0) == nil }
    }

    /// Explicit Copy/Share hydrates evicted rows one at a time. Selection
    /// retains only IDs/order/capabilities, not thumbnails or message bodies.
    public func archivedSelectionShare(copyAll: Bool = false) async -> SelectionShare? {
        guard let chosen = selection else { return nil }
        do {
            let reader = try await backend.openChatReader()
            let ids = try await Self.orderedSelection(reader, chat: chosen.chat, ids: chosen.ids)
            guard selection == chosen, !appLock.isLocked else { return nil }
            var files: [URL] = []
            var lines: [(body: String, stamp: String, author: String)] = []
            for id in ids {
                guard selection == chosen, !appLock.isLocked else { return nil }
                guard let message = try await Self.selectedRecord(reader, chat: chosen.chat, id: id) else { continue }
                if !copyAll, let url = message.mediaURL { files.append(url) }
                if copyAll || message.content.media == nil {
                    let body = MessageTranscript.line(for: message, mentionName: { chats.displayName($0) })
                    let author = message.fromMe ? session.account?.name.nonEmpty ?? String(localized: "You")
                        : chats.personName(message.sender, hint: message.senderName)
                    lines.append((body, MessageTranscript.stamp(message.timestamp, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent), author))
                }
            }
            guard selection == chosen, !appLock.isLocked else { return nil }
            let text = lines.map { lines.count == 1 ? $0.body : "[\($0.stamp)] \($0.author): \($0.body)" }
            return SelectionShare(text: text.isEmpty ? nil : text.joined(separator: "\n"), files: files)
        } catch {
            if selection == chosen { post(.error, String(localized: "Could not read the selected messages")) }
            return nil
        }
    }

    @concurrent
    static func orderedSelection(_ reader: any ChatReaderProtocol, chat: String, ids: [String]) async throws -> [String] {
        try reader.selectedIds(chat: chat, ids: ids)
    }

    @concurrent
    private static func selectedRecord(_ reader: any ChatReaderProtocol, chat: String, id: String) async throws -> MessageRecord? {
        try reader.message(chat: chat, id: id)
    }

    @concurrent
    private static func selectionPage(_ reader: any ChatReaderProtocol, chat: String, before: PageKey) async throws -> [MessageRecord] {
        try reader.page(chat: chat, before: before, limit: 60)
    }
}
