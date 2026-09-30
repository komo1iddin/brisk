import AVFoundation
import ImageIO
import Observation
import SwiftUI
import ZapFastCore

/// What the media editor is doing: the item shown, the tool in use, the
/// brush and colours, undo, and the pictures and players it has loaded.
/// Edits themselves live in the model's attachments.
@MainActor
@Observable
final class MediaEditorState {
    enum Mode: Equatable {
        case browse
        case crop
        case draw
        /// Writing, or rewriting, one piece of text.
        case text
    }

    var selectedID: Attachment.ID?
    var mode: Mode = .browse
    /// The overlay picked to move, size or turn.
    var selectedOverlay: MediaOverlay.ID?

    var brush: MediaStroke.Brush = .pen
    var drawColor = MediaColor(red: 1, green: 0.23, blue: 0.19)
    var aspect: CropAspect = .free
    var portrait = false

    /// The text being written, shown large in the middle until it is done.
    var draftText: MediaOverlay?
    /// Whether the draft replaces an overlay already on the picture.
    var draftIsNew = true

    /// Bumped by the window's close button; the editor then closes as its
    /// own ✕ does.
    var closeRequests = 0

    /// The edit as it was when cropping began, for Cancel.
    var editBeforeCrop: MediaEdit?

    /// The canvas's longer side on screen, so new words and emoji start
    /// at a size that reads well however large the picture is.
    var displayLongSide: CGFloat = 800

    private(set) var photos: [Attachment.ID: EditorPhoto] = [:]
    private(set) var videos: [Attachment.ID: EditorVideo] = [:]

    private var undoStack: [Attachment.ID: [MediaEdit]] = [:]
    private var redoStack: [Attachment.ID: [MediaEdit]] = [:]

    func canUndo(_ id: Attachment.ID) -> Bool { !(undoStack[id] ?? []).isEmpty }
    func canRedo(_ id: Attachment.ID) -> Bool { !(redoStack[id] ?? []).isEmpty }

    /// Remembers `edit` as the state to go back to; a new change forgets
    /// what was undone.
    func record(_ edit: MediaEdit, for id: Attachment.ID) {
        undoStack[id, default: []].append(edit)
        if undoStack[id]!.count > 100 { undoStack[id]!.removeFirst() }
        redoStack[id] = nil
    }

    func undo(_ current: MediaEdit, for id: Attachment.ID) -> MediaEdit? {
        guard let previous = undoStack[id]?.popLast() else { return nil }
        redoStack[id, default: []].append(current)
        return previous
    }

    func redo(_ current: MediaEdit, for id: Attachment.ID) -> MediaEdit? {
        guard let next = redoStack[id]?.popLast() else { return nil }
        undoStack[id, default: []].append(current)
        return next
    }

    // MARK: Loading

    /// Loads the picture or player for an attachment, once.
    func load(_ attachment: Attachment) async {
        switch attachment.media {
        case .photo:
            guard photos[attachment.id] == nil, let photo = await EditorPhoto.load(attachment.kind) else { return }
            photos[attachment.id] = photo
        case .video:
            guard videos[attachment.id] == nil, let url = attachment.fileURL,
                  let info = try? await MediaExport.videoInfo(url) else { return }
            let video = EditorVideo(url: url, info: info)
            videos[attachment.id] = video
            await video.loadFrames()
        case .none:
            break
        }
    }

    #if DEBUG
    /// The editor's own actions by name, for the debug script.
    var debugActions: [String: () -> Void] = [:]
    nonisolated(unsafe) static weak var debugLatest: MediaEditorState?

    func preload(_ photo: EditorPhoto, for id: Attachment.ID) {
        photos[id] = photo
    }
    #endif

    func forget(_ id: Attachment.ID) {
        videos[id]?.player.pause()
        photos[id] = nil
        videos[id] = nil
        undoStack[id] = nil
        redoStack[id] = nil
    }

    func pauseAll() {
        for video in videos.values { video.player.pause() }
    }
}

/// A crop's shape, as the aspect menu offers it.
enum CropAspect: Hashable {
    case free
    case original
    case ratio(Double, Double)

    static let presets: [CropAspect] = [.ratio(1, 1), .ratio(16, 9), .ratio(3, 2), .ratio(4, 3), .ratio(5, 4), .ratio(7, 5)]

    var title: String {
        switch self {
        case .free: String(localized: "Freeform")
        case .original: String(localized: "Original")
        case .ratio(1, 1): String(localized: "Square")
        case .ratio(let width, let height): "\(Int(width)):\(Int(height))"
        }
    }

    /// Width over height in pixels, or `nil` when free.
    func value(source: CGSize, portrait: Bool) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return source.width / max(source.height, 1)
        case .ratio(let width, let height):
            let ratio = CGFloat(width / height)
            return portrait ? 1 / ratio : ratio
        }
    }

    /// Square and the source's own shape have no other way round.
    var turns: Bool {
        switch self {
        case .free, .original, .ratio(1, 1): false
        default: true
        }
    }
}

/// A photo as the editor draws it: upright, at most 2400 pixels a side,
/// with its pixelated twin for the pixelate brush.
struct EditorPhoto {
    let image: CGImage
    let pixelated: CGImage?
    /// The photo's own upright size, for the quality choice.
    let original: CGSize

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    @concurrent
    static func load(_ kind: Attachment.Kind) async -> EditorPhoto? {
        let image: CGImage?
        var original: CGSize?
        switch kind {
        case .file(let url):
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                let turned = ((properties[kCGImagePropertyOrientation] as? UInt32) ?? 1) >= 5
                original = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            }
            image = source.flatMap {
                CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400,
                ] as CFDictionary)
            }
        case .image(let pasted):
            image = pasted.cgImage
        }
        guard let image else { return nil }
        return EditorPhoto(
            image: image, pixelated: MediaExport.pixelate(image),
            original: original ?? CGSize(width: image.width, height: image.height)
        )
    }
}

/// A video in the editor: its player, which keeps to the trimmed part,
/// and a strip of frames for the trimmer.
@MainActor
@Observable
final class EditorVideo {
    let url: URL
    let info: MediaExport.VideoInfo
    @ObservationIgnored let player: AVPlayer
    private(set) var frames: [CGImage] = []
    private(set) var time: Double = 0
    private(set) var playing = false
    /// The part kept; the player loops inside it.
    var range: ClosedRange<Double>

    @ObservationIgnored private var observer: Any?

    init(url: URL, info: MediaExport.VideoInfo) {
        self.url = url
        self.info = info
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        range = 0...max(info.duration, 0.1)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        time = seconds
        let rate = player.rate
        if playing != (rate != 0) { playing = rate != 0 }
        if rate != 0, seconds >= range.upperBound - 0.01 {
            seek(range.lowerBound)
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if time >= range.upperBound - 0.05 || time < range.lowerBound { seek(range.lowerBound) }
            player.play()
        }
        playing = player.rate != 0
    }

    func seek(_ seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Frames spread across the video, small, for the trimmer.
    func loadFrames(count: Int = 14) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let duration = info.duration
        guard duration > 0 else { return }
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var loaded: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { loaded.append(image) }
        }
        frames = loaded
    }
}
