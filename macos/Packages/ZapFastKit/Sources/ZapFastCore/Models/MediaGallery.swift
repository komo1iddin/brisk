import Foundation
import ZapFastBridge

/// The photos and videos of a chat, as the media viewer steps through
/// them: oldest first, among the messages loaded so far. Stickers, voice
/// messages, documents and round video messages stay in their bubbles.
public enum MediaGallery {
    /// What the viewer shows for a message, if anything.
    public enum Kind: Equatable, Sendable {
        case photo
        case video
        /// A GIF: a short silent video that loops.
        case gif
    }

    public static func kind(of message: MessageRecord) -> Kind? {
        switch message.content {
        case .image: .photo
        case .video(_, _, _, let gif, let note):
            note ? nil : (gif ? .gif : .video)
        default: nil
        }
    }

    public static func items(in messages: [MessageRecord]) -> [MessageRecord] {
        messages.filter { kind(of: $0) != nil }
    }

    /// The caption written with it, if any.
    public static func caption(of message: MessageRecord) -> String? {
        switch message.content {
        case .image(let caption, _), .video(let caption, _, _, _, _):
            caption.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        default: nil
        }
    }

    /// Items grouped by the month they were sent in, newest month first,
    /// for the grid of all media.
    public static func months(
        of items: [MessageRecord], calendar: Calendar = .current
    ) -> [(month: Date, items: [MessageRecord])] {
        var groups: [Date: [MessageRecord]] = [:]
        for item in items {
            let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp))
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            groups[month, default: []].append(item)
        }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }
}

/// The media viewer's request: which chat, and the message shown first.
public struct MediaViewerRequest: Equatable, Sendable {
    public let chat: String
    public let message: String

    public init(chat: String, message: String) {
        self.chat = chat
        self.message = message
    }
}
