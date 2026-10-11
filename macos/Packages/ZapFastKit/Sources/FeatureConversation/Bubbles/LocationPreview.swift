import AppKit
import ZapFastDesign

/// A location's preview comes from its message, without a map-service request.
enum LocationPreview {
    static func load(_ thumbnail: Data?, key: String, points: CGFloat) async -> NSImage? {
        guard let thumbnail else { return nil }
        return await Thumbnails.load(thumbnail, key: key, points: points)
    }
}
