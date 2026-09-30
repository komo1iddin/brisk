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
        let appearances: [(NSAppearance.Name, String)] = [(.aqua, ""), (.darkAqua, "-dark")]
        var windows: [(NSWindow, TimelineController, String, Bool)] = []
        for (name, suffix) in appearances {
            for drawn in [true, false] {
                let controller = TimelineController()
                controller.drawsBubbles = drawn
                let scrollView = controller.makeScrollView()
                let window = NSWindow(
                    contentRect: NSRect(x: -4000, y: 0, width: 760, height: 3200),
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

    /// The bubble gallery, and the kinds drawn since.
    static let messages: [MessageRecord] = BubbleGallery.messages + [
        extra("30", from: "a", content: .revoked),
        extra("31", fromMe: true, content: .revoked),
        extra("32", from: "b", content: .unsupported(what: "Payment message")),
        extra("33", from: "b", content: .phoneOnly(viewOnce: true, liveLocation: false, once: nil)),
    ]

    private static func extra(_ id: String, from sender: String = "me", fromMe: Bool = false, content: MessageContent) -> MessageRecord {
        MessageRecord(
            id: id, chat: "gallery@g.us", sender: "\(sender)@s.whatsapp.net",
            senderName: ["a": "Aziza", "b": "Bobur"][sender], fromMe: fromMe,
            timestamp: 1_790_000_000 + (Int64(id) ?? 0) * 60, content: content, status: fromMe ? .read : .none,
            deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Attachment"
        )
    }
}
#endif
