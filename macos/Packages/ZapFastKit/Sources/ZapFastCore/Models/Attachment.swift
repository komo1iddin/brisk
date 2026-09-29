import CoreGraphics
import Foundation
import ZapFastBridge

/// Something staged above the composer, sent with the composer's text as
/// its caption (upstream's `Pending`): a file, or a pasted image.
public struct Attachment: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file(URL)
        case image(PastedImage)
    }

    public let id = UUID()
    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var fileURL: URL? {
        if case .file(let url) = kind { url } else { nil }
    }
}

extension PastedImage {
    /// A pasted picture as upstream's `SendImage` wants it: straight-alpha
    /// RGBA rows, no padding.
    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Core Graphics only draws premultiplied; undo it.
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        self.init(width: UInt32(width), height: UInt32(height), rgba: Data(bytes))
    }

    /// The picture again, for a preview.
    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
