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

    /// What the timeline has decoded already, so a row scrolled back into view
    /// does not parse its animation again.
    private static let decoded = NSCache<NSString, LottieAnimation>()

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

    /// Where unpacked stickers are kept: beside the app's other caches.
    static let cache: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appending(path: Bundle.main.bundleIdentifier ?? "ZapFast", directoryHint: .isDirectory)
            .appending(path: "Lottie", directoryHint: .isDirectory)
    }()

    /// Unpacks the sticker, reads its animation and shows its first frame;
    /// false when the file holds nothing that plays. A later `load` makes
    /// this one's answer moot.
    @discardableResult
    func load(file: URL, cache: URL = LottieStickerView.cache) async -> Bool {
        loads += 1
        let load = loads
        isReady = false
        let key = file.path(percentEncoded: false) as NSString
        let animation: LottieAnimation?
        let folder: URL
        if let known = Self.decoded.object(forKey: key) {
            animation = known
            folder = cache.appending(path: file.lastPathComponent, directoryHint: .isDirectory)
                .appending(path: "animation", directoryHint: .isDirectory)
        } else if let unpacked = try? await WasArchive.unpack(file, into: cache) {
            animation = await Self.decode(unpacked.animation)
            folder = unpacked.folder
        } else {
            return false
        }
        guard load == loads, let animation else { return false }
        Self.decoded.setObject(animation, forKey: key)
        player.imageProvider = FilepathImageProvider(filepath: folder.path(percentEncoded: false))
        player.animation = animation
        player.currentProgress = 0
        isReady = true
        return true
    }

    /// Parsed off the main actor: an animation may carry its pictures inline.
    @concurrent
    private static func decode(_ json: URL) async -> LottieAnimation? {
        try? LottieAnimation.from(data: Data(contentsOf: json))
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
