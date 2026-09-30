#if DEBUG
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore

/// With `ZAPFAST_VIEWER_SCRIPT=right,left,grid,…` the shell opens the media
/// viewer over a chat of made-up photos (one not downloaded), without
/// starting the backend, and plays the steps a second apart: keys
/// (`right`, `left`, `escape`, `space`, `zoomIn`, `zoomOut`, `zoomReset`,
/// `copy`) and `click:x:y` from the window's top left. It prints what the
/// viewer shows after each and quits: a way to catch a crash without
/// clicking.
enum MediaViewerScript {
    static let chat = "viewer@s.whatsapp.net"

    static var steps: [String]? {
        ProcessInfo.processInfo.environment["ZAPFAST_VIEWER_SCRIPT"]?.split(separator: ",").map(String.init)
    }

    @MainActor
    static func run(model: AppModel, steps: [String]) {
        let messages = sampleMessages()
        model.debugApply([.messages(chat: chat, messages: messages, older: false, complete: true)])
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1100, height: 740),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.toolbar = NSToolbar(identifier: "Script")
        window.contentView = NSHostingView(rootView: ViewerScriptHost(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if let first = messages.first(where: { MediaGallery.kind(of: $0) != nil }) { model.openMediaViewer(first) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                print("script: \(step)")
                fflush(stdout)
                guard let viewer = NSApp.windows.first(where: { $0 is ViewerWindow }) else {
                    print("script: viewer closed")
                    break
                }
                if step.hasPrefix("click:") {
                    let parts = step.split(separator: ":").compactMap { Double($0) }
                    let point = NSPoint(x: parts[0], y: viewer.frame.height - parts[1])
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: viewer.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                        ) { viewer.sendEvent(event) }
                    }
                } else if let (code, flags, characters) = key(step) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: viewer.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                        ) { NSApp.postEvent(event, atStart: false) }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                print("script: open \(model.mediaViewer != nil)")
            }
            print("script: done")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static func key(_ step: String) -> (UInt16, NSEvent.ModifierFlags, String)? {
        switch step {
        case "right": (124, [], "\u{F703}")
        case "left": (123, [], "\u{F702}")
        case "escape": (53, [], "\u{1B}")
        case "space": (49, [], " ")
        case "zoomIn": (24, .command, "=")
        case "zoomOut": (27, .command, "-")
        case "zoomReset": (29, .command, "0")
        case "copy": (8, .command, "c")
        default: nil
        }
    }

    /// Four photos with captions, the third not downloaded, and a text.
    private static func sampleMessages() -> [MessageRecord] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "zapfast-viewer-script")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Int64(Date.now.timeIntervalSince1970)
        return (0..<5).map { index in
            let id = "m\(index)"
            if index == 4 {
                return record(id: id, timestamp: now - 60, content: .text(text: "hello", preview: nil))
            }
            let url = directory.appending(path: "\(id).png")
            if !FileManager.default.fileExists(atPath: url.path) { writePicture(to: url, hue: Double(index) / 4) }
            let media = MediaInfo(mime: "image/png", size: 1, width: 1600, height: 1000, path: index == 2 ? nil : url.path)
            let caption = index == 1 ? "A caption long enough to wrap onto a second line when the window is narrow." : nil
            return record(id: id, timestamp: now - Int64(3_600 * (4 - index)), content: .image(caption: caption, media: media))
        }
    }

    private static func record(id: String, timestamp: Int64, content: MessageContent) -> MessageRecord {
        MessageRecord(
            id: id, chat: chat, sender: "a@s.whatsapp.net", senderName: "Sample", fromMe: false, timestamp: timestamp,
            content: content, status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: ""
        )
    }

    private static func writePicture(to url: URL, hue: Double) {
        guard let context = CGContext(
            data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor(srgbRed: hue, green: 0.5, blue: 1 - hue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 500, y: 250, width: 600, height: 500))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

private struct ViewerScriptHost: View {
    let model: AppModel

    var body: some View {
        Color.gray
            .background {
                MediaViewerPresenter(
                    chatID: MediaViewerScript.chat, model: model,
                    isPresented: model.mediaViewer?.chat == MediaViewerScript.chat,
                    theme: model.chatTheme(for: nil)
                )
            }
    }
}
#endif
