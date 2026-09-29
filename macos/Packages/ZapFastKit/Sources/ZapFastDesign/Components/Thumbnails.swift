import AppKit
import ImageIO

/// Decodes images at the size they are drawn, off the main actor, and keeps
/// them for the life of the process. `NSCache` is thread-safe; it predates
/// `Sendable`, hence the unsafe marker.
public enum Thumbnails {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    /// An image from a file, decoded to `points` on its longest side.
    @concurrent
    public static func load(_ url: URL, points: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let key = "\(url.path(percentEncoded: false))@\(Int(points * scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source, points: points, scale: scale, key: key)
    }

    /// An image from bytes (a message's JPEG preview), decoded to `points`.
    @concurrent
    public static func load(_ data: Data, key: String, points: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let key = "\(key)@\(Int(points * scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source, points: points, scale: scale, key: key)
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
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let result = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        )
        cache.setObject(result, forKey: key)
        return result
    }
}
