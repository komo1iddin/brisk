import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures prepared the way upstream prepares a group or profile photo
/// (`square_picture_jpeg`, private to its worker): a centred square, at
/// most 640 pixels a side, JPEG at quality 0.85.
nonisolated public enum PictureEncoding {
    static let side = 640

    public enum Failure: LocalizedError {
        case unreadable
        public var errorDescription: String? { String(localized: "This picture could not be read.") }
    }

    @concurrent
    public static func squareJPEG(from url: URL) async throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  // Big enough that the square's short side survives.
                  kCGImageSourceThumbnailMaxPixelSize: 8192,
              ] as CFDictionary) else { throw Failure.unreadable }
        return try squareJPEG(image)
    }

    static func squareJPEG(_ image: CGImage) throws -> Data {
        let short = min(image.width, image.height)
        let crop = CGRect(x: (image.width - short) / 2, y: (image.height - short) / 2, width: short, height: short)
        guard let square = image.cropping(to: crop) else { throw Failure.unreadable }
        let size = min(short, side)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Failure.unreadable }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { throw Failure.unreadable }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return data as Data
    }
}
