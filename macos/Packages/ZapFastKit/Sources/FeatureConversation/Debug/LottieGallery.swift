#if DEBUG
import AppKit
import ZapFastCore

/// Development aid: a made-up Lottie sticker in a real window, one still on
/// its first frame and one moving, captured as the window server composites
/// it (`cacheDisplay` draws Core Animation layers wrongly). Writes `<path>`
/// a little after the moving one starts and `-later` a little after that.
public enum LottieGallery {
    public static func render(to path: String, done: @escaping () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-lottie-gallery", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let file = TimelineGallery.lottieSticker(in: folder) else {
            done()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: 0, width: 370, height: 200), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.backgroundColor = .white
        let still = LottieStickerView(frame: NSRect(x: 20, y: 20, width: 160, height: 160))
        let moving = LottieStickerView(frame: NSRect(x: 190, y: 20, width: 160, height: 160))
        window.contentView?.addSubview(still)
        window.contentView?.addSubview(moving)
        window.orderFrontRegardless()
        Task {
            let loaded = await still.load(file: URL(filePath: file))
            await moving.load(file: URL(filePath: file))
            print("lottie loaded: \(loaded)")
            moving.setPlaying(true)
            try? await Task.sleep(for: .milliseconds(500))
            write(window, to: path)
            try? await Task.sleep(for: .milliseconds(600))
            write(window, to: path.replacingOccurrences(of: ".png", with: "-later.png"))
            done()
        }
    }

    private static func write(_ window: NSWindow, to path: String) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?
                  .takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }
}
#endif
