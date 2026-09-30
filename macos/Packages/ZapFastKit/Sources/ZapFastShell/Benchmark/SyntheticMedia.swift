import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Files for the benchmark's media messages, drawn once into a folder of
/// the benchmark's caches: photos of a few shapes, each with the small JPEG
/// preview a message carries, a sticker, a one-page PDF with its preview,
/// and stand-ins for voice and video files (never played).
nonisolated struct SyntheticMedia: Sendable {
    struct Picture: Sendable {
        let path: String
        let width: UInt32
        let height: UInt32
        /// The preview a message carries before its file is downloaded.
        let thumbnail: Data
        let bytes: UInt64
    }

    let photos: [Picture]
    let sticker: Picture
    let document: Picture
    let voicePath: String
    let videoPath: String

    /// Makes the files unless an earlier run left them.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shapes: [(Int, Int)] = [(1280, 960), (960, 1280), (1280, 720), (1080, 1080), (720, 1280), (1600, 900)]
        photos = shapes.enumerated().map { index, shape in
            Self.picture(
                at: directory.appending(path: "photo-\(index).jpg"), width: shape.0, height: shape.1,
                type: .jpeg, seed: index, opaque: true
            )
        }
        sticker = Self.picture(
            at: directory.appending(path: "sticker.png"), width: 512, height: 512, type: .png, seed: 11, opaque: false
        )
        document = Self.pdf(at: directory.appending(path: "document.pdf"))
        voicePath = Self.stub(at: directory.appending(path: "voice.ogg"), bytes: 24_000)
        videoPath = Self.stub(at: directory.appending(path: "video.mp4"), bytes: 400_000)
    }

    // MARK: Drawing

    private static func picture(at url: URL, width: Int, height: Int, type: UTType, seed: Int, opaque: Bool) -> Picture {
        let image = draw(width: width, height: height, seed: seed, opaque: opaque)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            write(image, to: url, type: type)
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init) ?? 0
        return Picture(
            path: url.path(percentEncoded: false), width: UInt32(width), height: UInt32(height),
            thumbnail: thumbnail(of: image), bytes: bytes
        )
    }

    /// Soft colour fields and a few circles, different for every seed.
    private static func draw(width: Int, height: Int, seed: Int, opaque: Bool) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var generator = SplitMix64(seed: UInt64(seed) &+ 100)
        func hue() -> CGFloat { CGFloat(generator.next() % 360) / 360 }
        let top = NSColor(hue: hue(), saturation: 0.45, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: hue(), saturation: 0.6, brightness: 0.55, alpha: 1).cgColor
        if opaque {
            let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        for _ in 0..<7 {
            let radius = CGFloat(generator.next() % UInt64(max(width, height) / 4)) + 40
            let center = CGPoint(x: CGFloat(generator.next() % UInt64(width)), y: CGFloat(generator.next() % UInt64(height)))
            context.setFillColor(NSColor(hue: hue(), saturation: 0.7, brightness: 0.9, alpha: opaque ? 0.55 : 1).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        return context.makeImage()!
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// A JPEG about 64 pixels on its longest side, as WhatsApp sends.
    private static func thumbnail(of image: CGImage) -> Data {
        let scale = 64 / CGFloat(max(image.width, image.height))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let small = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// One A4 page of lines, as a report looks from afar.
    private static func pdf(at url: URL) -> Picture {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            var box = page
            if let context = CGContext(url as CFURL, mediaBox: &box, nil) {
                context.beginPDFPage(nil)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(page)
                context.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
                context.fill(CGRect(x: 60, y: 760, width: 300, height: 24))
                for line in 0..<30 {
                    let width = CGFloat(380 + (line * 37) % 95)
                    context.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
                    context.fill(CGRect(x: 60, y: 720 - CGFloat(line) * 20, width: width, height: 8))
                }
                context.endPDFPage()
                context.closePDF()
            }
        }
        let preview = draw(width: 420, height: 594, seed: 5, opaque: true)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init) ?? 0
        return Picture(path: url.path(percentEncoded: false), width: 595, height: 842, thumbnail: thumbnail(of: preview), bytes: bytes)
    }

    private static func stub(at url: URL, bytes: Int) -> String {
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? Data(count: bytes).write(to: url)
        }
        return url.path(percentEncoded: false)
    }
}
