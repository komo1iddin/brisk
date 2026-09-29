import AppKit
import ImageIO
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
            guard playing, animation == nil else { return }
            animation = await AnimatedFrames.load(url, points: points)
        }
    }
}

/// Decoded frames and how long each shows.
nonisolated final class AnimatedFrames: Sendable {
    let frames: [CGImage]
    /// Cumulative end time of each frame, in seconds.
    private let ends: [TimeInterval]
    private let started = Date.now

    init(frames: [CGImage], delays: [TimeInterval]) {
        self.frames = frames
        var total: TimeInterval = 0
        ends = delays.map { total += $0; return total }
    }

    func frame(at date: Date) -> CGImage {
        guard let duration = ends.last, duration > 0 else { return frames[0] }
        let time = date.timeIntervalSince(started).truncatingRemainder(dividingBy: duration)
        let index = ends.firstIndex { time < $0 } ?? frames.count - 1
        return frames[index]
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, AnimatedFrames> = {
        let cache = NSCache<NSString, AnimatedFrames>()
        // Only a few play at once (under the pointer); keep a handful.
        cache.countLimit = 12
        return cache
    }()

    @concurrent
    static func load(_ url: URL, points: CGFloat, scale: CGFloat = 2) async -> AnimatedFrames? {
        let key = "\(url.path(percentEncoded: false))@\(Int(points * scale))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(points * scale)),
        ]
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(frame)
            delays.append(delay(of: source, at: index))
        }
        guard frames.count > 1 else { return nil }
        let animation = AnimatedFrames(frames: frames, delays: delays)
        cache.setObject(animation, forKey: key)
        return animation
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
