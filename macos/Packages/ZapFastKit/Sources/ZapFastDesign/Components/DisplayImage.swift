import CoreGraphics
import Synchronization

/// Puts decoded images into the pixel layout and colour space Core Animation
/// shows as they are.
///
/// Anything else (RGBA byte order, another colour space) Core Animation
/// converts while committing the frame, on the main thread; in Telefast's
/// scroll traces that conversion filled the gaps between frames whenever
/// photos arrived. Decoders call `prepare` on their own threads instead.
public nonisolated enum DisplayImage {
    private static let target = Mutex(CGColorSpace(name: CGColorSpace.sRGB)!)
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// The colour space of the display the app's windows are on.
    public static var colorSpace: CGColorSpace {
        get { target.withLock { $0 } }
        set { target.withLock { $0 = newValue } }
    }

    public static func prepare(_ image: CGImage) -> CGImage {
        let space = colorSpace
        if image.colorSpace == space, image.bitmapInfo.rawValue == bitmapInfo { return image }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: bitmapInfo
        ) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
