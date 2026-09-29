#if DEBUG
import AppKit
import FeatureConversation
import SwiftUI
import ZapFastCore

/// Development aid: with `ZAPFAST_SNAPSHOT=/path/to.png` in the environment,
/// renders the main window's SwiftUI content to a PNG a few seconds after
/// launch, then keeps running. AppKit islands (the message table, the
/// composer field) draw as empty space, since `ImageRenderer` only draws
/// SwiftUI. Absent from release builds.
///
/// `ZAPFAST_SNAPSHOT_GALLERY=/path/to.png` instead renders every kind of
/// bubble with made-up content, without starting the backend, and quits.
enum DebugSnapshot {
    static var galleryPath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_GALLERY"]
    }

    static func renderGalleryAndQuit() {
        guard let path = galleryPath else { return }
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(
            data: FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery"),
            caches: FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery-cache")
        ))
        for scheme in [ColorScheme.light, .dark] {
            let content = BubbleGallery(model: model)
                .frame(width: 900)
                .background(Color(nsColor: .textBackgroundColor))
                .environment(\.colorScheme, scheme)
            let target = scheme == .dark ? path.replacingOccurrences(of: ".png", with: "-dark.png") : path
            write(content, to: target)
        }
        NSApp.terminate(nil)
    }

    private static func write(_ content: some View, to path: String) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            NSLog("ZapFast snapshot: rendering failed")
            return
        }
        try? png.write(to: URL(filePath: path))
    }

    static func scheduleIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_DELAY"] ?? "") ?? 4
        let scheme: ColorScheme = ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_DARK"] != nil ? .dark : .light
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let content = RootView(model: model)
                .frame(width: 1100, height: 740)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                NSLog("ZapFast snapshot: rendering failed")
                return
            }
            do {
                try png.write(to: URL(filePath: path))
                NSLog("ZapFast snapshot written")
            } catch {
                NSLog("ZapFast snapshot: \(error.localizedDescription)")
            }
        }
    }
}
#endif
