#if DEBUG
import AppKit
import FeatureConversation
import SwiftUI
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Development aid: with `ZAPFAST_SNAPSHOT=/path/to.png` in the environment,
/// renders the main window's SwiftUI content to a PNG a few seconds after
/// launch, then keeps running. AppKit islands (the message table, the
/// composer field) draw as empty space, since `ImageRenderer` only draws
/// SwiftUI. Absent from release builds.
///
/// `ZAPFAST_SNAPSHOT_GALLERY=/path/to.png` instead renders every kind of
/// bubble with made-up content, without starting the backend, and quits.
///
/// `ZAPFAST_DUMP_MENUS=1` prints the menu bar (titles, key equivalents,
/// actions) to standard output, without starting the backend, and quits:
/// the way to check a shortcut is really there.
enum DebugSnapshot {
    static var dumpsMenus: Bool {
        ProcessInfo.processInfo.environment["ZAPFAST_DUMP_MENUS"] != nil
    }

    static func dumpMenusAndQuit() {
        func dump(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem {
                let modifiers = item.keyEquivalentModifierMask
                let keys = item.keyEquivalent.isEmpty ? "" : [
                    modifiers.contains(.control) ? "⌃" : "", modifiers.contains(.option) ? "⌥" : "",
                    modifiers.contains(.shift) ? "⇧" : "", modifiers.contains(.command) ? "⌘" : "",
                    item.keyEquivalent.uppercased(),
                ].joined()
                print(String(repeating: "  ", count: depth) + item.title, keys)
                if let submenu = item.submenu { dump(submenu, depth: depth + 1) }
            }
        }
        if let menu = NSApp.mainMenu { dump(menu, depth: 0) }
        fflush(stdout)
        NSApp.terminate(nil)
    }

    static var galleryPath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_GALLERY"]
    }

    static func renderGalleryAndQuit() {
        guard let path = galleryPath else { return }
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(
            data: FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery"),
            caches: FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery-cache")
        ))
        let theme = model.chatTheme(for: nil)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            let content = BubbleGallery(model: model)
                .environment(\.chatTheme, theme)
                .frame(width: 900)
                .background { WallpaperView(theme.wallpaper) }
                .background(Color(nsColor: .textBackgroundColor))
                .environment(\.colorScheme, scheme)
            write(content, to: path.replacingOccurrences(of: ".png", with: "\(suffix).png"))
            // Every preset theme, as the Appearance settings preview it.
            let presets = LazyVGrid(columns: Array(repeating: GridItem(.fixed(260)), count: 5), spacing: 12) {
                ForEach(ThemePresets.all) { preset in
                    VStack {
                        ThemePreview(theme: ChatTheme(preset.appearance, photos: model.themes), detailed: true)
                            .frame(width: 260, height: 170)
                            .clipShape(.rect(cornerRadius: 12))
                        Text(preset.name).font(.caption)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            write(presets, to: path.replacingOccurrences(of: ".png", with: "-themes\(suffix).png"))
        }
        // The media editor in each of its tools.
        for mode in MediaEditorGallery.modes {
            let editor = MediaEditorGallery.view(mode: mode, model: model)
                .frame(width: 1000, height: 680)
            write(editor, to: path.replacingOccurrences(of: ".png", with: "-editor-\(mode).png"))
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
