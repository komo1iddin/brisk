#if DEBUG
import AppKit
import ZapFastBridge
import ZapFastCore

/// Development aid: made-up chats in every state a row shows, through the
/// real sidebar table, drawn rows on the left and the SwiftUI rows they
/// replace on the right, so the two can be compared by eye. Each is a real
/// window off screen, captured as the window server composites it
/// (`cacheDisplay` draws Core Animation layers' colours differently).
public enum SidebarGallery {
    /// Writes `<path>` and `<path>-dark` with the second chat selected, and
    /// `-b` beside each with the third. Calls `done` when all are written.
    public static func render(to path: String, done: @escaping () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-sidebar-gallery", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appending(path: "photo.png")
        writePhoto(to: photo)
        let chats = chats
        let model = AppModel(backend: GalleryBackend(events: [
            .me(id: own, lid: nil, name: "Gallery", about: nil),
            .chats(chats: chats),
            .link(state: .connected),
            .drafts(drafts: [Draft(chat: chats[10].id, text: "Ertaga yozaman, hozir bandman")]),
            .typing(chat: chats[8].id, sender: chats[8].id, composing: true),
            .typing(chat: chats[9].id, sender: "998901112233@s.whatsapp.net", composing: true),
            .contacts(contacts: [ContactRecord(id: "998901112233@s.whatsapp.net", fullName: "Shahlo Rahimova", firstName: "Shahlo", pushName: nil)]),
            .avatar(id: chats[0].id, full: false, path: photo.path(percentEncoded: false)),
        ]), paths: AppPaths(data: folder, caches: folder), preferences: Preferences(defaults: UserDefaults(suiteName: "zapfast-sidebar-gallery")!))
        model.start()
        SidebarRowView.emphasizesInGallery = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let rows: [SidebarRow] = [
                .folder(id: "locked", title: String(localized: "Locked Chats"), systemImage: "lock", count: nil) {},
                .folder(id: "archived", title: String(localized: "Archived"), systemImage: "archivebox", count: 2) {},
            ] + chats.map(SidebarRow.chat)
            var tables: [(window: NSWindow, controller: ChatTableController, dark: Bool)] = []
            for dark in [false, true] {
                for drawn in [true, false] {
                    let controller = ChatTableController()
                    controller.drawsRows = drawn
                    let scrollView = controller.makeScrollView()
                    let window = NSWindow(
                        contentRect: NSRect(x: -4000, y: 0, width: 340, height: 1100),
                        styleMask: [.borderless], backing: .buffered, defer: false
                    )
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.backgroundColor = .windowBackgroundColor
                    scrollView.frame = window.contentView!.bounds
                    scrollView.autoresizingMask = [.width, .height]
                    window.contentView!.addSubview(scrollView)
                    window.orderFrontRegardless()
                    controller.update(rows: rows, selection: chats[1].id, model: model) { _ in }
                    tables.append((window, controller, dark))
                }
            }
            // Avatars load and SwiftUI settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                capture(tables, suffix: "", path: path)
                for table in tables {
                    table.controller.update(rows: rows, selection: chats[2].id, model: model) { _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    capture(tables, suffix: "-b", path: path)
                    for table in tables { table.window.orderOut(nil) }
                    done()
                }
            }
        }
    }

    private static func capture(
        _ tables: [(window: NSWindow, controller: ChatTableController, dark: Bool)], suffix: String, path: String
    ) {
        for dark in [false, true] {
            let pair = tables.filter { $0.dark == dark }
            let images = pair.map { table -> NSBitmapImageRep? in
                table.controller.tableView.layoutSubtreeIfNeeded()
                table.window.displayIfNeeded()
                CATransaction.flush()
                return windowImage(table.window).map(NSBitmapImageRep.init(cgImage:))
            }
            guard let drawn = images.first ?? nil, let hosted = images.last ?? nil else { continue }
            let name = path.replacingOccurrences(of: ".png", with: "\(suffix)\(dark ? "-dark" : "").png")
            write(drawn, hosted, background: pair[0].window, to: name)
        }
    }

    /// `CGWindowListCreateImage`, which Swift no longer offers but the
    /// system still answers for the app's own windows.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // Only this window, at its own bounds, at the best resolution.
        return capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    private static func write(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep, background window: NSWindow, to path: String) {
        let width = left.pixelsWide + right.pixelsWide + 8
        let height = max(left.pixelsHigh, right.pixelsHigh)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
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
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    }

    private static let own = "998900000000@s.whatsapp.net"

    /// Each state a row draws: unread counts, muted and pinned chats, the
    /// reader's own messages in each delivery state, typing, a draft, a
    /// group's sender, a channel, an empty group and a name too long.
    static var chats: [ChatSummary] {
        let now = Int64(Date.now.timeIntervalSince1970)
        let day: Int64 = 86_400
        return [
            chat("998901000001", "Aziza Karimova", activity: now - 300, last: preview("Ertaga soat 10 da uchrashamizmi?")),
            chat("998901000002", "Bobur", activity: now - 900, unread: 3, last: preview("Qalesan? Ishlar yaxshimi?")),
            chat("120363000000000003", "Oila", kind: .group, activity: now - 1_800, unread: 128, muted: true,
                 last: preview("Rasmlarni yubordim 📷", sender: "998901000009@s.whatsapp.net", name: "Dilnoza")),
            chat("998901000004", "Jasur", activity: now - day, pinned: true, last: preview("Ok 👍", fromMe: true, status: .read)),
            chat("998901000005", "Madina", activity: now - 2 * day, last: preview(
                "Loyiha bo'yicha hujjatni yubordim, ko'rib chiqib fikringizni yozing. Ayniqsa ikkinchi bo'lim.",
                fromMe: true, status: .delivered
            )),
            chat("998901000006", "Otabek", activity: now - 3 * day, last: preview("Men hozir yo'ldaman", fromMe: true, status: .pending)),
            chat("998901000007", "Sardor", activity: now - 4 * day, last: preview("Let me check", fromMe: true, status: .failed)),
            chat("998901000008", "Nodira", activity: now - 5 * day, marked: true, last: preview("Rahmat! 🙏", fromMe: true, status: .sent)),
            chat("998901000010", "Kamola", activity: now - 9 * day, last: preview("Salom!")),
            chat("120363000000000011", "Ishxona", kind: .group, activity: now - 10 * day, last: preview("Bugungi reja", sender: own, fromMe: true, status: .read)),
            chat("998901000012", "Rustam", activity: now - 20 * day, last: preview("Haha 😂😂")),
            chat("120363000000000013", "Yangiliklar", kind: .broadcast, activity: now - 30 * day, muted: true, pinned: true,
                 last: preview("Bugun ob-havo bulutli bo'ladi")),
            chat("120363000000000014", "Yangi guruh", kind: .group, activity: now - 40 * day, last: nil),
            chat("120363000000000015", "Juda uzun nomli guruh: loyiha muhokamasi va boshqa ishlar", kind: .group,
                 activity: now - 400 * day, unread: 1_500, last: preview("Привет! Как дела?", sender: "998901000016@s.whatsapp.net", name: "Aziz")),
            // Names and messages cut short at different places, to compare
            // where each row stops them.
            chat("998901000017", "Abdulazizxon Abdurahmonov Toshkentlik", activity: now - 3_000, last: preview(
                "Tomorrow works for me. Let's do 3pm, and I'll bring the notes"
            )),
            chat("998901000018", "Mirzohid Muhammadaliyev Samarqanddan", activity: now - 3_100, muted: true, last: preview(
                "Liquid Glass faqat navigatsiya qatlamida bo'lishi kerak, kontentda emas"
            )),
            chat("998901000019", "Gulnoraxon Xudoyberdiyeva Farg'onalik", activity: now - 3_200, unread: 7, last: preview(
                "The quick brown fox jumps over the lazy dog. Pack my box"
            )),
        ]
    }

    private static func preview(
        _ text: String, sender: String = "998901000099@s.whatsapp.net", name: String? = nil,
        fromMe: Bool = false, status: DeliveryState = .none
    ) -> ChatPreview {
        ChatPreview(fromMe: fromMe, sender: fromMe ? own : sender, senderName: name, summary: text, full: text, status: status)
    }

    private static func chat(
        _ number: String, _ name: String, kind: ChatKind = .direct, activity: Int64, unread: UInt32 = 0,
        marked: Bool = false, muted: Bool = false, pinned: Bool = false, last: ChatPreview?
    ) -> ChatSummary {
        let id = kind == .direct ? "\(number)@s.whatsapp.net" : "\(number)@g.us"
        var last = last
        if kind == .direct, var preview = last, !preview.fromMe {
            preview.sender = id
            last = preview
        }
        return ChatSummary(
            id: id, name: name, groupSubjectKnown: true, kind: kind, lastActivity: activity,
            unread: unread, markedUnread: marked, archived: false, pinned: pinned, pinnedAt: pinned ? activity : 0,
            mutedUntil: muted ? 0 : nil, last: last, favorite: false, favoritePosition: 0, participants: [],
            readOnly: false, left: false, infoLocked: false, admin: false, locked: false, ephemeralExpiration: nil,
            labels: [], hasCustomSound: false, isChannel: kind == .broadcast, looksUnread: unread > 0 || marked, phone: nil
        )
    }

    /// A made-up profile picture.
    private static func writePhoto(to url: URL) {
        let size = 160
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(NSColor(hue: 0.58, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(NSColor(hue: 0.08, saturation: 0.5, brightness: 0.95, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 50, y: 70, width: 60, height: 60))
        context.fillEllipse(in: CGRect(x: 25, y: -40, width: 110, height: 100))
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Hands the gallery's events over once started, as the bridge would.
private final class GalleryBackend: Backend {
    private let events: [BridgeEvent]

    init(events: [BridgeEvent]) {
        self.events = events
    }

    func start(paths: AppPaths, verbose: Bool, deliver: @escaping @MainActor ([BridgeEvent]) -> Void) throws {
        let events = events
        DispatchQueue.main.async {
            MainActor.assumeIsolated { deliver(events) }
        }
    }

    func send(_ command: BridgeCommand) {}
    func shutdown() {}
}
#endif
