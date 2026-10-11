import AppKit
import CryptoKit
import ImageIO
import QuickLookThumbnailing

/// Decodes images at the size they are drawn, off the main actor, and keeps
/// the recent ones, up to 64 MB of decoded pixels (a count alone let 600
/// photo-sized images hold hundreds of megabytes). `NSCache` is
/// thread-safe; it predates `Sendable`, hence the unsafe marker.
public enum Thumbnails {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// An image from a file, decoded to `points` on its longest side. A file
    /// rewritten in place (a new profile picture) is decoded afresh.
    @concurrent
    public static func load(_ url: URL, points: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path(percentEncoded: false))#\(modified)@\(Int(points * scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source, points: points, scale: scale, key: key)
    }

    /// An image from bytes (a message's JPEG preview), decoded to `points`.
    @concurrent
    public static func load(_ data: Data, key: String, points: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let key = byteKey(data, key: key, points: points, scale: scale)
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source, points: points, scale: scale, key: key)
    }

    /// The image `load(_:points:)` gave for this file, if it is still kept:
    /// a reused cell shows it at once instead of its grey ground first.
    public nonisolated static func cached(_ url: URL, points: CGFloat, scale: CGFloat = 2) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return cache.object(forKey: "\(url.path(percentEncoded: false))#\(modified)@\(Int(points * scale))" as NSString)
    }

    /// The image of these bytes, never a previous preview under the same name.
    public nonisolated static func cached(_ data: Data, key: String, points: CGFloat, scale: CGFloat = 2) -> NSImage? {
        cache.object(forKey: byteKey(data, key: key, points: points, scale: scale))
    }

    /// Separates the caller's namespaces even when their names contain separators.
    public nonisolated static func scope(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// A small preview's content identity, also used to reload edited previews.
    public nonisolated static func contentID(_ data: Data?) -> String {
        guard let data else { return "none" }
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private nonisolated static func byteKey(_ data: Data, key: String, points: CGFloat, scale: CGFloat) -> NSString {
        "\(scope([key, contentID(data)]))@\(Int(points * scale))#\(scale)" as NSString
    }

    /// The page `document(_:size:)` gave for this file, if it is still kept.
    public nonisolated static func cachedDocument(_ url: URL, size: CGSize, scale: CGFloat = 2) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return cache.object(forKey: "page:\(url.path(percentEncoded: false))#\(modified)@\(Int(size.width * scale))x\(Int(size.height * scale))" as NSString)
    }

    /// A document's first page as Quick Look draws it (a PDF's cover), fit
    /// within `size`.
    @concurrent
    public static func document(_ url: URL, size: CGSize, scale: CGFloat = 2) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let key = "page:\(url.path(percentEncoded: false))#\(modified)@\(Int(size.width * scale))x\(Int(size.height * scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated private static func decode(
        _ source: CGImageSource,
        points: CGFloat,
        scale: CGFloat,
        key: NSString
    ) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(points * scale)),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = DisplayImage.prepare(decoded)
        let result = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        )
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}
