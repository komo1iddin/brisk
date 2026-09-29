import CoreGraphics
import Foundation
import ImageIO
import ZapFastBridge

/// A picture chosen for the sticker maker (upstream's `StickerPicture`):
/// its file, pixel size, and whether any of it is see-through.
public struct StickerPicture: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let width: UInt32
    public let height: UInt32
    public let transparent: Bool

    /// Reads a picture off the main actor; nil when it is not one.
    @concurrent
    public static func inspect(_ url: URL) async -> StickerPicture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        return StickerPicture(
            url: url, width: UInt32(image.width), height: UInt32(image.height),
            transparent: hasTransparency(image)
        )
    }

    /// Whether any pixel is see-through, judged on a small copy.
    nonisolated private static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let side = 64
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: side, height: side))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }
}
