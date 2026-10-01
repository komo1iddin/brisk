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
        // `ZAPFAST_SNAPSHOT_SELECTING=1`: picking messages, the second picked.
        if ProcessInfo.processInfo.environment["ZAPFAST_SNAPSHOT_SELECTING"] != nil {
            model.select(messages[1])
        }
        let appearances: [(NSAppearance.Name, String)] = [(.aqua, ""), (.darkAqua, "-dark")]
        var windows: [(NSWindow, TimelineController, String, Bool)] = []
        for (name, suffix) in appearances {
            for drawn in [true, false] {
                let controller = TimelineController()
                controller.drawsBubbles = drawn
                let scrollView = controller.makeScrollView()
                let window = NSWindow(
                    contentRect: NSRect(x: -4000, y: 0, width: 760, height: 4000),
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
                    jump: nil, scrollRequest: nil, onReachTop: {}, onScrollState: { _ in }
                )
                windows.append((window, controller, suffix, drawn))
            }
        }
        // Pictures decode and SwiftUI rows settle; then the top of each
        // table, and its end (`-end`), which the window's height leaves
        // out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (_, controller, _, _) in windows {
                let clip = controller.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
                controller.scrollView.reflectScrolledClipView(clip)
            }
            controller(windows).forEach { $0.tableView.layoutSubtreeIfNeeded() }
            capture(windows, appearances: appearances, end: false, path: path)
            for (_, controller, _, _) in windows {
                let clip = controller.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(0, controller.tableView.bounds.height - clip.bounds.height)))
                controller.scrollView.reflectScrolledClipView(clip)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                capture(windows, appearances: appearances, end: true, path: path)
                for (window, _, _, _) in windows { window.orderOut(nil) }
                done()
            }
        }
    }

    private static func controller(_ windows: [(NSWindow, TimelineController, String, Bool)]) -> [TimelineController] {
        windows.map(\.1)
    }

    private static func capture(
        _ windows: [(NSWindow, TimelineController, String, Bool)],
        appearances: [(NSAppearance.Name, String)],
        end: Bool,
        path: String
    ) {
        for (_, suffix) in appearances {
            let pair = windows.filter { $0.2 == suffix }
            let images = pair.map { _, controller, _, _ -> NSBitmapImageRep? in
                let table = controller.tableView
                let rect = controller.scrollView.contentView.documentVisibleRect
                guard let rep = table.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
                table.cacheDisplay(in: rect, to: rep)
                return rep
            }
            guard let drawn = images.first ?? nil, let hosted = images.last ?? nil else { continue }
            let name = path.replacingOccurrences(of: ".png", with: "\(suffix)\(end ? "-end" : "").png")
            write(side: drawn, by: hosted, background: pair[0].0, to: name)
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
            extra("50", from: "a", content: .document(media: MediaInfo(
                mime: "application/pdf", size: 2_400_000, width: nil, height: nil, path: nil
            ), fileName: "Loyiha rejasi va arxitektura bo'yicha batafsil hujjat.pdf", caption: "Ko'rib chiqing", pages: 12), thumbnail: portrait.thumbnail),
            extra("51", fromMe: true, content: .document(media: MediaInfo(
                mime: "application/zip", size: 18_300_000, width: nil, height: nil, path: sticker.path
            ), fileName: "Build logs.zip", caption: nil, pages: nil)),
            extra("52", from: "b", content: .text(
                text: "Buni o'qing: https://developer.apple.com/design/",
                preview: LinkPreviewInfo(
                    url: "https://developer.apple.com/design/", title: "Design - Apple Developer",
                    description: "Get the resources to design great apps and games for all Apple platforms, with guidelines, videos and templates."
                )
            ), thumbnail: landscape.thumbnail),
            extra("54", fromMe: true, content: .audio(
                media: MediaInfo(mime: "audio/ogg; codecs=opus", size: 24_000, width: nil, height: nil, path: sticker.path),
                seconds: 75, voiceNote: true, waveform: Data((0..<64).map { UInt8(10 + ($0 * 53) % 90) })
            )),
            extra("55", from: "a", content: .audio(
                media: MediaInfo(mime: "audio/mpeg", size: 3_400_000, width: nil, height: nil, path: sticker.path),
                seconds: 214, voiceNote: false, waveform: Data()
            )),
            extra("53", fromMe: true, content: .text(
                text: "https://github.com/crmne/zapfast",
                preview: LinkPreviewInfo(url: "https://github.com/crmne/zapfast", title: "crmne/zapfast", description: nil)
            )),
            // Files without a page: the card as wide as its texts, a
            // caption wrapped to it.
            extra("56", from: "b", content: .document(media: MediaInfo(
                mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 37_000,
                width: nil, height: nil, path: nil
            ), fileName: "AT526.docx", caption: nil, pages: 2), forwarded: true),
            extra("57", from: "b", content: .document(media: MediaInfo(
                mime: "application/pdf", size: 611_000, width: nil, height: nil, path: nil
            ), fileName: "Hisobot-771.pdf", caption: "Savdo palatasidan keladigan asl shakl, shu ko'rinishda saqlab qo'ying", pages: 1)),
            extra("58", from: "b", content: .document(media: MediaInfo(
                mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 92_000,
                width: nil, height: nil, path: nil
            ), fileName: "Narxlar.xlsx", caption: nil, pages: nil)),
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
