#if DEBUG
import AppKit
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Development aid: the gallery's messages through the real timeline, as
/// drawn bubbles beside the SwiftUI rows they replace, so the two can be
/// compared by eye. Each is a real window off screen, captured with
/// `cacheDisplay`, which draws AppKit and SwiftUI alike.
public enum TimelineGallery {
    /// Writes `<path>` (light) and `<path>-dark` side by side: drawn on the
    /// left, SwiftUI on the right. Calls `done` when both are written.
    public static func render(model: AppModel, to path: String, done: @escaping () -> Void) {
        // Undownloaded media show their size, as with downloads off.
        model.preferences.autoDownload = false
        let messages = messages
        let appearances: [(NSAppearance.Name, String)] = [(.aqua, ""), (.darkAqua, "-dark")]
        var windows: [(NSWindow, TimelineController, String, Bool)] = []
        for (name, suffix) in appearances {
            for drawn in [true, false] {
                let controller = TimelineController()
                controller.drawsBubbles = drawn
                let scrollView = controller.makeScrollView()
                let window = NSWindow(
                    contentRect: NSRect(x: -4000, y: 0, width: 760, height: 5200),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.appearance = NSAppearance(named: name)
                window.backgroundColor = .textBackgroundColor
                scrollView.frame = window.contentView!.bounds
                scrollView.autoresizingMask = [.width, .height]
                window.contentView!.addSubview(scrollView)
                window.orderFrontRegardless()
                controller.update(
                    chatID: "gallery@g.us", messages: messages, revision: 1, isGroup: true, model: model,
                    style: TimelineStyle(theme: model.chatTheme(for: nil), textScale: 1), unread: nil,
                    selecting: false, jump: nil, scrollRequest: nil, onReachTop: {}, onScrollState: { _ in }
                )
                windows.append((window, controller, suffix, drawn))
            }
        }
        // Pictures decode and SwiftUI rows settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (name, suffix) in appearances {
                _ = name
                let pair = windows.filter { $0.2 == suffix }
                let images = pair.map { window, controller, _, _ -> NSBitmapImageRep? in
                    controller.tableView.scroll(.zero)
                    let table = controller.tableView
                    let height = min(table.bounds.height, window.frame.height)
                    let rect = NSRect(x: 0, y: 0, width: table.bounds.width, height: height)
                    guard let rep = table.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
                    table.cacheDisplay(in: rect, to: rep)
                    return rep
                }
                guard let drawn = images.first ?? nil, let hosted = images.last ?? nil else { continue }
                write(side: drawn, by: hosted, background: pair[0].0, to: path.replacingOccurrences(of: ".png", with: "\(suffix).png"))
            }
            for (window, _, _, _) in windows { window.orderOut(nil) }
            done()
        }
    }

    private static func write(side left: NSBitmapImageRep, by right: NSBitmapImageRep, background window: NSWindow, to path: String) {
        let width = left.pixelsWide + right.pixelsWide + 8
        let height = max(left.pixelsHigh, right.pixelsHigh)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: left.pixelsWide, y: 0, width: 8, height: height))
        if let image = left.cgImage {
            context.draw(image, in: CGRect(x: 0, y: height - left.pixelsHigh, width: left.pixelsWide, height: left.pixelsHigh))
        }
        if let image = right.cgImage {
            context.draw(image, in: CGRect(x: left.pixelsWide + 8, y: height - right.pixelsHigh, width: right.pixelsWide, height: right.pixelsHigh))
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }

    /// The bubble gallery, and the kinds drawn since, with pictures made
    /// here: files for downloaded media and small previews for the rest.
    static var messages: [MessageRecord] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-gallery-media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let landscape = picture(width: 1280, height: 960, hue: 0.55, to: folder.appending(path: "landscape.jpg"))
        let portrait = picture(width: 960, height: 1280, hue: 0.08, to: folder.appending(path: "portrait.jpg"))
        let sticker = picture(width: 512, height: 512, hue: 0.9, to: folder.appending(path: "sticker.png"), clear: true)
        let quote = QuotedMessage(id: "1", sender: "a@s.whatsapp.net", senderName: "Aziza", summary: "Salom! Qalaysiz?", mentions: [])
        return BubbleGallery.messages + [
            extra("30", from: "a", content: .revoked),
            extra("31", fromMe: true, content: .revoked),
            extra("32", from: "b", content: .unsupported(what: "Payment message")),
            extra("33", from: "b", content: .phoneOnly(viewOnce: true, liveLocation: false, once: nil)),
            extra("40", from: "a", content: .image(caption: "Tog'dagi manzara, kechqurun. Juda chiroyli joy ekan, keyingi safar birga boramiz.", media: MediaInfo(
                mime: "image/jpeg", size: 420_000, width: 1280, height: 960, path: landscape.path
            )), thumbnail: landscape.thumbnail),
            extra("41", fromMe: true, content: .image(caption: nil, media: MediaInfo(
                mime: "image/jpeg", size: 1_300_000, width: 960, height: 1280, path: nil
            )), thumbnail: portrait.thumbnail),
            extra("42", from: "b", content: .video(caption: "Video", media: MediaInfo(
                mime: "video/mp4", size: 8_400_000, width: 1280, height: 720, path: nil
            ), seconds: 95, gif: false, note: false), thumbnail: landscape.thumbnail, quoted: quote, forwarded: true),
            extra("43", from: "b", content: .sticker(media: MediaInfo(
                mime: "image/webp", size: 30_000, width: 512, height: 512, path: sticker.path
            ), animated: false)),
            extra("44", fromMe: true, content: .video(caption: nil, media: MediaInfo(
                mime: "video/mp4", size: 900_000, width: 480, height: 480, path: nil
            ), seconds: 18, gif: false, note: true), thumbnail: portrait.thumbnail),
            extra("45", fromMe: true, content: .video(caption: nil, media: MediaInfo(
                mime: "video/mp4", size: 2_000_000, width: 640, height: 480, path: "/dev/null"
            ), seconds: 4, gif: true, note: false), thumbnail: landscape.thumbnail),
        ]
    }

    private static func extra(
        _ id: String,
        from sender: String = "me",
        fromMe: Bool = false,
        content: MessageContent,
        thumbnail: Data? = nil,
        quoted: QuotedMessage? = nil,
        forwarded: Bool = false
    ) -> MessageRecord {
        MessageRecord(
            id: id, chat: "gallery@g.us", sender: "\(sender)@s.whatsapp.net",
            senderName: ["a": "Aziza", "b": "Bobur"][sender], fromMe: fromMe,
            timestamp: 1_790_000_000 + (Int64(id) ?? 0) * 60, content: content, status: fromMe ? .read : .none,
            deliveredAt: nil, readAt: nil, quoted: quoted, reactions: [], edited: false,
            mentions: [], forwarded: forwarded, thumbnail: thumbnail, summary: "Attachment"
        )
    }

    /// A made-up picture written to `url`, and its 64-pixel JPEG preview.
    private static func picture(width: Int, height: Int, hue: CGFloat, to url: URL, clear: Bool = false) -> (path: String, thumbnail: Data) {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if !clear {
            context.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(NSColor(hue: hue + 0.3, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: width / 5, y: height / 5, width: width * 3 / 5, height: height * 3 / 5))
        context.setFillColor(NSColor(hue: hue + 0.6, saturation: 0.7, brightness: 0.6, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 6))
        let image = context.makeImage()!
        let rep = NSBitmapImageRep(cgImage: image)
        let data = clear ? rep.representation(using: .png, properties: [:]) : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        try? data?.write(to: url)
        let small = NSImage(cgImage: image, size: NSSize(width: width, height: height))
        let thumbnail = NSImage(size: NSSize(width: 64, height: 64 * height / width), flipped: false) { rect in
            small.draw(in: rect)
            return true
        }
        let thumbnailData = thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .jpeg, properties: [.compressionFactor: 0.6]) ?? Data()
        return (url.path(percentEncoded: false), thumbnailData)
    }
}
#endif
