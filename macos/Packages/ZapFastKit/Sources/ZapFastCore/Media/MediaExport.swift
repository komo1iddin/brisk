import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Words or an emoji drawn by the interface for the export, sized for a
/// canvas whose longer side is the length it was asked for: the picture's
/// pixels are the canvas's.
public struct RenderedOverlay: @unchecked Sendable {
    public let overlay: MediaOverlay
    public let image: CGImage

    public init(overlay: MediaOverlay, image: CGImage) {
        self.overlay = overlay
        self.image = image
    }
}

/// Draws an overlay for a canvas whose longer side is this many pixels.
public typealias OverlayRenderer = @MainActor (MediaOverlay, CGFloat) -> CGImage?

/// Makes the file that is sent from a photo or video and its `MediaEdit`:
/// photos are redrawn and saved as JPEG at the chosen quality (which also
/// leaves their location and camera details behind); videos are trimmed,
/// silenced, drawn on and re-encoded with AVFoundation.
nonisolated public enum MediaExport {
    public enum Failure: LocalizedError {
        case unreadable
        case noVideo
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "This picture could not be read.")
            case .noVideo: String(localized: "This video could not be read.")
            case .exportFailed(let reason): String(localized: "The video could not be prepared: \(reason)")
            }
        }
    }

    /// A photo loaded for export: its pixels upright, and the canvas the
    /// edit is drawn on, in output pixels.
    public struct PhotoPlan: @unchecked Sendable {
        let image: CGImage
        /// The upright source's size in its own pixels.
        let sourceSize: CGSize
        /// The whole canvas at output scale.
        public let canvas: CGSize
        /// The crop at output scale: what is saved.
        public let output: CGSize
    }

    // MARK: Photos

    /// Reads the photo at the resolution the output needs.
    @concurrent
    public static func planPhoto(_ source: CGImageSource, edit: MediaEdit, quality: MediaQuality) async throws -> PhotoPlan {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw Failure.unreadable }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        // Orientations 5 to 8 stand the picture on its side.
        let upright = orientation >= 5
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        let geometry = geometry(source: upright, edit: edit, quality: quality)
        // Enough pixels that the straightened picture is not enlarged.
        let needed = max(upright.width, upright.height) * geometry.scale
            * MediaEdit.coverScale(canvas: geometry.canvas, straighten: edit.straighten)
        let side = min(Int(max(upright.width, upright.height)), Int(needed.rounded(.up)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, side),
        ] as CFDictionary) else { throw Failure.unreadable }
        return PhotoPlan(image: image, sourceSize: upright, canvas: geometry.canvas, output: geometry.output)
    }

    /// A pasted picture, already upright.
    public static func planPhoto(_ image: CGImage, edit: MediaEdit, quality: MediaQuality) -> PhotoPlan {
        let size = CGSize(width: image.width, height: image.height)
        let geometry = geometry(source: size, edit: edit, quality: quality)
        return PhotoPlan(image: image, sourceSize: size, canvas: geometry.canvas, output: geometry.output)
    }

    /// The canvas and output sizes: the crop's longer side is at most the
    /// quality's, and never enlarged.
    static func geometry(source: CGSize, edit: MediaEdit, quality: MediaQuality) -> (canvas: CGSize, output: CGSize, scale: CGFloat) {
        let native = edit.canvasSize(for: source)
        let cropped = CGSize(width: native.width * edit.crop.width, height: native.height * edit.crop.height)
        let scale = min(1, CGFloat(quality.photoSide) / max(cropped.width, cropped.height, 1))
        let canvas = CGSize(width: native.width * scale, height: native.height * scale)
        let output = CGSize(
            width: max(1, (cropped.width * scale).rounded()),
            height: max(1, (cropped.height * scale).rounded())
        )
        return (canvas, output, scale)
    }

    /// Draws the edited photo and encodes it as JPEG.
    @concurrent
    public static func renderPhoto(
        _ plan: PhotoPlan, edit: MediaEdit, overlays: [RenderedOverlay], quality: MediaQuality
    ) async throws -> Data {
        let width = Int(plan.output.width), height = Int(plan.output.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Failure.unreadable }
        context.interpolationQuality = .high
        // See-through pixels land on white, as they would on paper.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Put the crop's corner at the origin (Core Graphics counts up).
        let canvas = plan.canvas
        context.translateBy(x: -edit.crop.minX * canvas.width, y: -(1 - edit.crop.maxY) * canvas.height)
        drawPicture(plan.image, source: plan.sourceSize, in: context, canvas: canvas, edit: edit)

        let pixelated = edit.strokes.contains { $0.brush == .pixelate } ? pixelate(plan.image) : nil
        drawAnnotations(in: context, canvas: canvas, edit: edit, overlays: overlays) { context in
            if let pixelated {
                drawPicture(pixelated, source: plan.sourceSize, in: context, canvas: canvas, edit: edit)
            }
        }

        guard let result = context.makeImage() else { throw Failure.unreadable }
        return try jpeg(result, quality: quality.jpegQuality)
    }

    /// The source drawn on the canvas: turned, straightened, enlarged to
    /// cover, mirrored. The context counts up, from the canvas's corner.
    static func drawPicture(_ image: CGImage, source: CGSize, in context: CGContext, canvas: CGSize, edit: MediaEdit) {
        let native = edit.canvasSize(for: source)
        let scale = canvas.width / max(native.width, 1)
        let cover = MediaEdit.coverScale(canvas: canvas, straighten: edit.straighten)
        let drawn = CGSize(width: source.width * scale * cover, height: source.height * scale * cover)
        context.saveGState()
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        if edit.mirrored { context.scaleBy(x: -1, y: 1) }
        context.rotate(by: edit.angle)
        context.draw(image, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
        context.restoreGState()
    }

    /// Strokes, then words and emoji, over the canvas. `drawPixelated`
    /// draws the pixelated picture wherever the pixelate brush went.
    static func drawAnnotations(
        in context: CGContext, canvas: CGSize, edit: MediaEdit, overlays: [RenderedOverlay],
        drawPixelated: (CGContext) -> Void
    ) {
        for stroke in edit.strokes {
            let width = stroke.lineWidth(in: canvas)
            context.saveGState()
            // Strokes are kept counting down, as the screen draws them.
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: 1, y: -1)
            if stroke.brush == .pixelate {
                let area = stroke.path(in: canvas).copy(
                    strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1
                )
                context.addPath(area)
                context.clip()
                // Back to counting up for the picture.
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -canvas.height)
                drawPixelated(context)
            } else {
                context.setAlpha(stroke.brush.opacity)
                // One layer per stroke, so a see-through line does not
                // darken where it crosses itself.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.addPath(stroke.path(in: canvas))
                context.setStrokeColor(stroke.color.cgColor)
                context.setLineWidth(width)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
                context.endTransparencyLayer()
            }
            context.restoreGState()
        }
        for rendered in overlays {
            let overlay = rendered.overlay
            let size = CGSize(width: rendered.image.width, height: rendered.image.height)
            context.saveGState()
            // The centre, counting up; the turn is clockwise on screen.
            context.translateBy(x: overlay.center.x * canvas.width, y: (1 - overlay.center.y) * canvas.height)
            context.rotate(by: -overlay.rotation)
            context.draw(rendered.image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
    }

    /// Large squares of the picture's colours: a square is a 48th of the
    /// longer side, on screen and in the file alike.
    public static func pixelate(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let block = Double(max(image.width, image.height)) / 48
        let filter = CIFilter(name: "CIPixellate", parameters: [
            kCIInputImageKey: input.clampedToExtent(),
            kCIInputScaleKey: max(2, block),
            kCIInputCenterKey: CIVector(x: 0, y: 0),
        ])
        guard let output = filter?.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }

    static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return data as Data
    }

    // MARK: Videos

    /// A video's upright size and length.
    public struct VideoInfo: Sendable, Equatable {
        public let size: CGSize
        public let duration: Double
        public let hasSound: Bool
    }

    @concurrent
    public static func videoInfo(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = natural.applying(transform)
        let duration = try await asset.load(.duration).seconds
        let sound = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        return VideoInfo(
            size: CGSize(width: abs(upright.width), height: abs(upright.height)),
            duration: duration.isFinite ? duration : 0,
            hasSound: sound
        )
    }

    /// The longer side of a video's drawings at a quality: the size the
    /// export's preset produces at most.
    public static func videoSide(_ quality: MediaQuality) -> CGFloat {
        quality == .standard ? 960 : 1920
    }

    /// Writes the trimmed, silenced, drawn-on video as MP4 to `destination`.
    @concurrent
    public static func exportVideo(
        _ url: URL, edit: MediaEdit, overlays: [RenderedOverlay], quality: MediaQuality, to destination: URL
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration)
        let range: CMTimeRange = if let trim = edit.trim {
            CMTimeRange(
                start: CMTime(seconds: trim.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: min(trim.upperBound, duration.seconds), preferredTimescale: 600)
            )
        } else {
            CMTimeRange(start: .zero, duration: duration)
        }

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noVideo }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        if !edit.muted {
            for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
                let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try audio?.insertTimeRange(range, of: sourceAudio, at: .zero)
            }
        }

        let preset = quality == .standard ? AVAssetExportPreset960x540 : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw Failure.exportFailed(String(localized: "no encoder"))
        }
        if !edit.strokes.isEmpty || !overlays.isEmpty {
            let composed = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
            let size = composed.renderSize
            if let layer = annotationLayer(edit: edit, overlays: overlays, canvas: size) {
                let frame = CGRect(origin: .zero, size: size)
                let parent = CALayer(), videoLayer = CALayer(), drawing = CALayer()
                parent.frame = frame
                videoLayer.frame = frame
                drawing.frame = frame
                drawing.contents = layer
                drawing.contentsGravity = .resize
                parent.addSublayer(videoLayer)
                parent.addSublayer(drawing)
                composed.animationTool = AVVideoCompositionCoreAnimationTool(
                    postProcessingAsVideoLayer: videoLayer, in: parent
                )
                session.videoComposition = composed
            }
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
    }

    /// The strokes and overlays alone, on a see-through canvas.
    static func annotationLayer(edit: MediaEdit, overlays: [RenderedOverlay], canvas: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        drawAnnotations(in: context, canvas: canvas, edit: edit, overlays: overlays) { _ in }
        return context.makeImage()
    }

    // MARK: Files

    /// Where prepared files wait for upstream to read them. Old ones are
    /// removed at launch.
    public static func outgoingDirectory(in caches: URL) -> URL {
        caches.appending(path: "Outgoing", directoryHint: .isDirectory)
    }

    /// Removes prepared files older than a day: upstream reads a file as
    /// soon as it is sent, and a refused one is sent again long before.
    @concurrent
    public static func sweepOutgoing(in caches: URL, now: Date = .now) async {
        let directory = outgoingDirectory(in: caches)
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? files.removeItem(at: entry)
            }
        }
    }
}
