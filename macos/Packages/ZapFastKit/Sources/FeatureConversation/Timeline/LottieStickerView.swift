import AppKit
import Lottie
import ZapFastCore

/// A Lottie sticker, drawn by Lottie from the animation inside its `.was`
/// file. It shows its first frame and moves only when told to, as an
/// animated sticker does under the pointer.
final class LottieStickerView: NSView {
    private let player = LottieAnimationView()
    private var loads = 0
    private(set) var isReady = false
    private var unpacked: WasArchive.Unpacked?

    /// What the timeline has decoded already, so a row scrolled back into view
    /// does not parse its animation again.
    private static let decoded: NSCache<NSString, LottieAnimation> = {
        let cache = NSCache<NSString, LottieAnimation>()
        cache.countLimit = 24
        // JSON size is a cache cost estimate, not a measured model size.
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static var decoding: [String: (id: UUID, task: Task<LottieAnimation?, Never>)] = [:]
    nonisolated private static let decodeQueue = DispatchQueue(label: "zapfast.lottie-decode", qos: .userInitiated)

    override init(frame: NSRect) {
        super.init(frame: frame)
        player.contentMode = .scaleAspectFit
        player.loopMode = .loop
        player.backgroundBehavior = .pauseAndRestore
        player.shouldRasterizeWhenIdle = false
        addSubview(player)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        player.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Unpacks the sticker, reads its animation and shows its first frame;
    /// false when the file holds nothing that plays. A later `load` makes
    /// this one's answer moot.
    @discardableResult
    func load(file: URL, cache: URL? = nil) async -> Bool {
        loads += 1
        let load = loads
        isReady = false
        player.stop()
        player.animation = nil
        unpacked = nil
        // Downloaded stickers live inside their account's folders. Keep the
        // derived files there too, so account removal removes them together.
        let cache = cache ?? file.deletingLastPathComponent().appending(path: ".lottie-cache", directoryHint: .isDirectory)
        guard let unpacked = try? await WasArchive.unpack(file, into: cache),
              !Task.isCancelled, load == loads else { return false }
        let key = unpacked.animation.path(percentEncoded: false) as NSString
        let animation: LottieAnimation?
        if let known = Self.decoded.object(forKey: key) {
            animation = known
        } else {
            let path = unpacked.animation.path(percentEncoded: false)
            let pending: (id: UUID, task: Task<LottieAnimation?, Never>)
            if let known = Self.decoding[path] { pending = known }
            else {
                guard Self.decoding.count < 32 else { return false }
                // Retain the unpacked lease until the queued parser finishes.
                pending = (UUID(), Task { await Self.decode(unpacked.animation) })
                Self.decoding[path] = pending
            }
            animation = await pending.task.value
            if Self.decoding[path]?.id == pending.id { Self.decoding[path] = nil }
        }
        guard !Task.isCancelled, load == loads, let animation else { return false }
        let bytes = (try? unpacked.animation.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Self.decoded.setObject(animation, forKey: key, cost: bytes * 8)
        self.unpacked = unpacked
        player.imageProvider = FilepathImageProvider(filepath: unpacked.folder.path(percentEncoded: false))
        player.animation = animation
        player.currentProgress = 0
        isReady = true
        return true
    }

    /// Parsed off the main actor: an animation may carry its pictures inline.
    nonisolated private static func decode(_ json: URL) async -> LottieAnimation? {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                let animation: LottieAnimation? = autoreleasepool {
                    guard let size = try? json.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 8 * 1024 * 1024,
                          let data = try? Data(contentsOf: json), data.count <= 8 * 1024 * 1024 else { return nil }
                    return try? LottieAnimation.from(data: data)
                }
                continuation.resume(returning: animation)
            }
        }
    }

    func setPlaying(_ on: Bool) {
        guard isReady else { return }
        if on {
            player.play()
        } else {
            player.stop()
            player.currentProgress = 0
        }
    }
}
