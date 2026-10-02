#if DEBUG
import AppKit
import FeatureChats
import FeatureSettings
import FeatureConversation
import SwiftUI
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Development aid: with `ZAPFAST_SNAPSHOT=/path/to.png` in the environment,
/// renders the lock screen or linking to a PNG a few seconds after launch,
/// then keeps running (`ImageRenderer` draws only SwiftUI, and the chats
/// are AppKit). Absent from release builds.
///
/// `ZAPFAST_SNAPSHOT_GALLERY=/path/to.png` instead renders every kind of
/// bubble with made-up content, without starting the backend, and quits.
///
/// `ZAPFAST_SNAPSHOT_TIMELINE=/path/to.png` renders the same messages through
/// the real timeline, drawn bubbles beside SwiftUI rows, and quits.
///
/// `ZAPFAST_SNAPSHOT_SIDEBAR=/path/to.png` renders made-up chats in every
/// state through the real sidebar table, drawn rows beside SwiftUI rows,
/// and quits.
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

    /// A folder to draw the Settings tabs into, each from a real window so
    /// AppKit's controls draw; then the app quits.
    static var settingsPath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_SETTINGS"]
    }

    static func renderSettingsAndQuit(model: AppModel) {
        guard let folder = settingsPath else { return }
        let dark = ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_DARK"] != nil
        var windows: [NSWindow] = []
        for pane in SettingsDebug.panes(model: model) {
            let host = NSHostingController(rootView: pane.view.frame(width: 560))
            let window = NSWindow(contentViewController: host)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            window.title = pane.name
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for window in windows {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(filePath: folder).appending(path: "settings-\(window.title)\(dark ? "-dark" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }

    static var galleryPath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_GALLERY"]
    }

    /// `ZAPFAST_SNAPSHOT_TIMELINE=/path/to.png`: the gallery through the real
    /// timeline, drawn bubbles beside SwiftUI rows, light and dark; then
    /// the app quits.
    static var timelinePath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_TIMELINE"]
    }

    /// `ZAPFAST_SNAPSHOT_SIDEBAR=/path/to.png`: made-up chats through the
    /// real sidebar table, drawn rows beside SwiftUI rows, light and dark;
    /// then the app quits.
    static var sidebarPath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_SIDEBAR"]
    }

    /// `ZAPFAST_SNAPSHOT_LOTTIE=/path/to.png`: a made-up Lottie sticker, still
    /// and moving, in a real window; then the app quits.
    static var lottiePath: String? {
        ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_LOTTIE"]
    }

    static func renderLottieAndQuit() {
        guard let path = lottiePath else { return }
        LottieGallery.render(to: path) { NSApp.terminate(nil) }
    }

    static func renderSidebarAndQuit() {
        guard let path = sidebarPath else { return }
        SidebarGallery.render(to: path) { NSApp.terminate(nil) }
    }

    static func renderTimelineAndQuit() {
        guard let path = timelinePath else { return }
        let model = AppModel(backend: PreviewBackend(), paths: AppPaths(
            data: FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery"),
            caches: FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery-cache")
        ))
        TimelineGallery.render(model: model, to: path) { NSApp.terminate(nil) }
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
            // The lock screen or linking: ImageRenderer draws SwiftUI only.
            let content = RootScreen(model: model, locked: model.appLock.isLocked)
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
