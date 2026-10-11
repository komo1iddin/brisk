import AppKit
import ImageIO
import QuartzCore
import SwiftUI

/// An animated WebP or GIF (a sticker) that moves only while `playing`,
/// else shows `still`. Frames decode off the main actor the first time it
/// plays, at the size drawn, and stay cached for a while.
public struct AnimatedImage: View {
    private let url: URL
    private let still: NSImage?
    private let points: CGFloat
    private let playing: Bool

    @State private var animation: AnimatedFrames?

    public init(url: URL, still: NSImage?, points: CGFloat, playing: Bool) {
        self.url = url
        self.still = still
        self.points = points
        self.playing = playing
    }

    public var body: some View {
        Group {
            if playing, let animation, animation.frames.count > 1 {
                TimelineView(.animation) { context in
                    Image(decorative: animation.frame(at: context.date), scale: 2)
                        .resizable()
                        .scaledToFit()
                }
            } else if let still {
                Image(nsImage: still).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: playing ? url : nil) {
            guard playing else { animation = nil; return }
            guard animation == nil else { return }
            let loaded = await AnimatedFrames.load(url, points: points)
            guard !Task.isCancelled else { return }
            animation = loaded
        }
    }
}

/// Decoded frames and how long each shows.
public nonisolated final class AnimatedFrames: Sendable {
    public let frames: [CGImage]
    /// Cumulative end time of each frame, in seconds.
    private let ends: [TimeInterval]
    private let started = Date.now

    init(frames: [CGImage], delays: [TimeInterval]) {
        self.frames = frames
        var total: TimeInterval = 0
        ends = delays.map { total += $0; return total }
    }

    /// The frames as a Core Animation keyframe animation of a layer's
    /// contents, looping: it plays without the main thread.
    public func contentsAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        let total = max(ends.last ?? 0, 0.001)
        animation.values = frames
        animation.keyTimes = ([0] + ends.dropLast()).map { NSNumber(value: $0 / total) }
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }

    func frame(at date: Date) -> CGImage {
        guard let duration = ends.last, duration > 0 else { return frames[0] }
        let time = date.timeIntervalSince(started).truncatingRemainder(dividingBy: duration)
        let index = ends.firstIndex { time < $0 } ?? frames.count - 1
        return frames[index]
    }

    static let frameLimit = 150
    static let byteLimit = 24 * 1024 * 1024
    private static let loader = AnimatedFrameLoader()

    @concurrent
    public static func load(_ url: URL, points: CGFloat, scale: CGFloat = 2) async -> AnimatedFrames? {
        guard points.isFinite, scale.isFinite, points > 0, scale > 0, !Task.isCancelled,
              let values = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = values[.size] as? Int, size <= 64 * 1024 * 1024 else { return nil }
        let pixels = Int(min(640, points * scale))
        let key = "\(url.standardizedFileURL.path(percentEncoded: false))@\(size)@\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)@\(pixels)"
        return await loader.load(url, pixels: max(1, pixels), key: key)
    }

    @concurrent
    static func decode(_ url: URL, pixels: Int) async -> AnimatedFrames? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= frameLimit else { return nil }
        // Reserve for square RGBA frames and row alignment before decoding.
        // Oversized animations retain their complete timing at a smaller size.
        let budgetPixels = max(1, Int(sqrt(Double(byteLimit / count / 4))) - 16)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(pixels, budgetPixels),
            kCGImageSourceShouldCache: false,
        ]
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        var bytes = 0
        for index in 0..<count {
            guard !Task.isCancelled else { return nil }
            let frame: CGImage? = autoreleasepool {
                CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary).map(DisplayImage.prepare)
            }
            guard let frame else { return nil }
            let cost = frame.bytesPerRow * frame.height
            guard cost <= byteLimit - bytes else { return nil }
            bytes += cost
            frames.append(frame)
            delays.append(delay(of: source, at: index))
        }
        guard frames.count > 1 else { return nil }
        return AnimatedFrames(frames: frames, delays: delays)
    }

    /// A frame's delay; very short ones play at 10 fps, as browsers do.
    nonisolated private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (container, unclamped, clamped) in containers {
            guard let values = properties[container] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0
            return delay > 0.011 ? delay : 0.1
        }
        return 0.1
    }
}
