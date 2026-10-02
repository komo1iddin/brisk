#if DEBUG
import AppKit
import FeatureConversation
import FeatureSettings
import SwiftUI
import ZapFastBridge
import ZapFastDesign
import ZapFastCore

/// Development aid: commands posted from a shell, for checking the AppKit
/// windows without Accessibility (which scripting the app would need).
///
///     swift -e 'import Foundation; DistributedNotificationCenter.default()
///         .postNotificationName(.init("com.komoliddin.ZapFastMac.debug"), object: "tree")'
///
/// Each answer goes to `~/Library/Caches/<bundle id>/debug/<command>.txt`.
/// Answers name view classes, frames and counts, never what a chat holds.
///
/// - `tree`: the main window's views, safe areas and toolbar items.
/// - `resize:<steps>:<points>`: narrows and widens the window in steps,
///   timing each from `setFrame` until the run loop has drawn it.
/// - `select:<n>`: opens the sidebar's nth chat.
/// - `top:<n>`: scrolls the timeline to its top `n` times, half a second
///   apart, so older pages load.
/// - `action:<selector>`: sends an action up the responder chain.
/// - `shot`: the main window as the screen shows it, to `shot.png` (a
///   window of the app's own needs no screen recording permission).
/// - `react:<n>`, `sender:<n>`: the reaction picker, or the sender's page,
///   of the nth message from the bottom of the screen; answers with the
///   frames of the bubble and of the popover.
/// - `scroll:<points>`: scrolls the timeline by that much.
/// - `send <selector> <int> [<int>]`: calls a method of the timeline's
///   scroll view with whole numbers, to try AppKit's settings live.
/// - `open:<search|closesearch|newchat|window|info>`: opens the open
///   chat's search, a new chat, the chat in its own window, its info.
/// - `export:<n>[:media]`: exports the sidebar's nth chat to a temporary
///   folder, answers with the counts it wrote and how long it took, and
///   deletes the folder, so the real archive's reader can be checked without
///   anything of the chat being shown.
/// - `call:<ringing|calling|active|muted|waiting|video|request|group|groupringing|ended|none>`: shows the call
///   window for a made-up number, with no sound and no network;
///   `shot:call` captures it.
@MainActor
enum DebugCommands {
    private static var observer: NSObjectProtocol?

    static func start(model: AppModel) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.komoliddin.ZapFastMac.debug"), object: nil, queue: .main
        ) { notification in
            let command = notification.object as? String ?? ""
            MainActor.assumeIsolated { run(command, model: model) }
        }
    }

    private static func run(_ command: String, model: AppModel) {
        // `send <selector> <int>...`: selectors hold colons, so spaces part it.
        let parts = command.hasPrefix("send ")
            ? command.split(separator: " ").map(String.init)
            : command.split(separator: ":").map(String.init)
        guard let name = parts.first else { return }
        switch name {
        case "tree":
            write(name, tree())
        case "resize":
            let steps = parts.count > 1 ? Int(parts[1]) ?? 40 : 40
            let points = parts.count > 2 ? Double(parts[2]) ?? 12 : 12
            write(name, resize(steps: steps, points: points))
        case "select":
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            if model.sidebarOrder.indices.contains(index) { model.selectedChatID = model.sidebarOrder[index] }
            write(name, "selected \(index) of \(model.sidebarOrder.count)")
        case "top":
            let times = parts.count > 1 ? Int(parts[1]) ?? 10 : 10
            Task { write(name, await scrollToTop(times: times)) }
        case "open":
            guard parts.count > 1, let chat = model.selectedChatID else { return }
            switch parts[1] {
            case "search": model.openChatSearch(in: chat)
            case "closesearch": model.closeChatSearch()
            case "newchat": model.newChatShown = true
            case "window": model.openChatWindow(chat)
            case "info": model.showInfo(in: chat)
            default: break
            }
            write(name, parts[1])
        case "send":
            // send <selector> <int> [<int>] on the timeline's scroll view.
            guard parts.count > 1, let content = mainWindow()?.contentView,
                  let scrollView = timeline(in: content)?.enclosingScrollView else { return }
            let selector = Selector(parts[1])
            guard scrollView.responds(to: selector) else {
                write(name, "no \(parts[1])")
                return
            }
            let numbers = parts.dropFirst(2).compactMap { Int($0) }
            if numbers.count == 2 {
                typealias Call = @convention(c) (AnyObject, Selector, Int, Int) -> Void
                unsafeBitCast(scrollView.method(for: selector), to: Call.self)(scrollView, selector, numbers[0], numbers[1])
            } else {
                typealias Call = @convention(c) (AnyObject, Selector, Int) -> Void
                unsafeBitCast(scrollView.method(for: selector), to: Call.self)(scrollView, selector, numbers.first ?? 0)
            }
            write(name, "sent \(command)")
        case "scroll":
            // scroll:<points>: the timeline moves by that many points (up < 0).
            guard parts.count > 1, let delta = Double(parts[1]), let content = mainWindow()?.contentView,
                  let scrollView = timeline(in: content)?.enclosingScrollView else { return }
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
            scrollView.reflectScrolledClipView(clip)
            // As a hand on the trackpad would, for what shows only then.
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
            write(name, "at \(Int(clip.bounds.minY))")
        case "react", "sender":
            // react:<n> / sender:<n>: the picker, or the sender's page, of the
            // nth message from the bottom; answers with where it sits, then
            // where the popover window came up.
            guard let content = mainWindow()?.contentView, let table = timeline(in: content) else { return }
            let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let target = name == "react"
                ? TimelineDebug.react(in: table, model: model, fromBottom: n)
                : TimelineDebug.sender(in: table, fromBottom: n)
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                let others = NSApp.windows.filter { $0 !== mainWindow() && $0.isVisible }
                write(name, "\(target)\nwindow \(mainWindow()?.frame ?? .zero)\n"
                    + others.map { "\(NSStringFromClass(type(of: $0))) \($0.frame.integral) alpha \($0.alphaValue) level \($0.level.rawValue)" }
                        .joined(separator: "\n"))
            }
        case "layers":
            // layers:<class fragment>: the layers under the first view whose class name has it.
            func find(_ view: NSView, _ part: String) -> NSView? {
                if NSStringFromClass(type(of: view)).contains(part), view.frame.height < 80, view.frame.minY > 500 { return view }
                return view.subviews.lazy.compactMap { find($0, part) }.first
            }
            func dump(_ layer: CALayer, _ depth: Int, _ out: inout String) {
                guard depth < 14 else { return }
                let color = layer.backgroundColor.flatMap { NSColor(cgColor: $0) }.map { " bg=\($0.alphaComponent)" } ?? ""
                let filters = layer.filters.map { " filters=\($0.count)" } ?? ""
                let bg = layer.backgroundFilters.map { " bgfilters=\($0.count)" } ?? ""
                out += String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.frame.integral)\(color)\(filters)\(bg)\(layer.isHidden ? " hidden" : "")\n"
                for sub in layer.sublayers ?? [] { dump(sub, depth + 1, &out) }
            }
            guard let content = mainWindow()?.contentView, let view = find(content, parts.count > 1 ? parts[1] : "NSHostingView"),
                  let layer = view.layer else { write(name, "none"); return }
            var out = "\(type(of: view)) \(view.frame)\n"
            dump(layer, 0, &out)
            write(name, out)
        case "settings":
            // settings:<tab>: that tab in a window of its own, as tall as it makes itself.
            let tab = parts.count > 1 ? parts[1] : "chats"
            guard let pane = SettingsDebug.panes(model: model).first(where: { $0.name == tab }) else { return }
            let host = NSHostingController(rootView: pane.view.frame(width: 560))
            let window = NSWindow(contentViewController: host)
            window.title = tab
            window.makeKeyAndOrderFront(nil)
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                write(name, "\(tab) \(window.frame.size) content \(window.contentView?.frame.size ?? .zero)")
                let image = capture(window)
                if let data = image {
                    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appending(path: Bundle.main.bundleIdentifier ?? "ZapFastMac").appending(path: "debug")
                    try? data.write(to: folder.appending(path: "settings-\(tab).png"))
                }
                window.close()
            }
        case "windows":
            write(name, NSApp.windows.map {
                "\(NSStringFromClass(type(of: $0))) \"\($0.title)\" \($0.frame.integral) visible=\($0.isVisible) mask=\($0.styleMask.rawValue)"
            }.joined(separator: "\n"))
        case "front":
            // front: the main window becomes key, as glass and pockets draw
            // differently in a window that is not.
            NSApp.activate(ignoringOtherApps: true)
            mainWindow()?.makeKeyAndOrderFront(nil)
            write(name, "key \(mainWindow()?.isKeyWindow ?? false) active \(NSApp.isActive)")
        case "scrollbar":
            // scrollbar:on|off: the chat list's bar, as if the pointer were over it.
            // The chat list's, narrower than the chat's.
            func find(_ view: NSView) -> HoverScrollView? {
                if let found = view as? HoverScrollView, found.frame.width < 500 { return found }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let content = mainWindow()?.contentView, let bar = find(content) else { return }
            bar.setBarVisible(parts.count > 1 && parts[1] == "on")
            // scrollbar:on:<fraction>: the list scrolled that far, 0 top to 1 bottom.
            if parts.count > 2, let fraction = Double(parts[2]), let document = bar.documentView {
                let clip = bar.contentView
                let visible = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
                let y = -clip.contentInsets.top + fraction * (document.frame.height - visible)
                clip.scroll(to: NSPoint(x: 0, y: y))
                bar.reflectScrolledClipView(clip)
            }
            let scroller = bar.verticalScroller
            write(name, "bar frame \(bar.frame) clip \(bar.contentView.frame) bounds \(bar.contentView.bounds) insets \(bar.contentInsets) doc \(bar.documentView?.frame.size ?? .zero) scroller \(scroller?.frame ?? .zero) knobRect \(scroller?.rect(for: .knob) ?? .zero) slot \(scroller?.rect(for: .knobSlot) ?? .zero) flipped \(scroller?.isFlipped ?? false) knob \(scroller?.knobProportion ?? -1) value \(scroller?.doubleValue ?? -1) style \(bar.scrollerStyle.rawValue)")
        case "call":
            let shown = parts.count > 1 ? parts[1] : ""
            let phase: CallPhase? = switch shown {
            case "ringing": .ringing
            case "calling": .calling
            case "active", "muted", "waiting", "video", "request", "group": .active
            case "groupringing": .ringing
            case "ended": .ended(reason: .peerHungUp)
            default: nil
            }
            let made = { (session: UInt64, chat: String, phase: CallPhase) in
                CallInfo(
                    session: session, chat: chat, incoming: phase == .ringing,
                    videoOffered: shown == "video", phase: phase, muted: shown == "muted",
                    camera: false, peerVideo: shown == "video" && session == 1,
                    videoRequested: shown == "request" && session == 1,
                    group: shown.hasPrefix("group"), caller: shown.hasPrefix("group") ? "998922222222@s.whatsapp.net" : nil,
                    participants: shown == "group" ? [
                        CallParticipant(chat: "998922222222@s.whatsapp.net", joined: true),
                        CallParticipant(chat: "998933333333@s.whatsapp.net", joined: true),
                        CallParticipant(chat: "998944444444@s.whatsapp.net", joined: false),
                    ] : []
                )
            }
            model.calls.debugShow(
                phase.map { made(1, "998900000000@s.whatsapp.net", $0) },
                waiting: shown == "waiting" ? made(2, "998911111111@s.whatsapp.net", .ringing) : nil
            )
            write(name, "\(phase.map { "\($0)" } ?? "none")")
        case "export":
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let media = parts.count > 2 && parts[2] == "media"
            guard model.sidebarOrder.indices.contains(index) else {
                write(name, "no chat \(index) of \(model.sidebarOrder.count)")
                return
            }
            let parent = FileManager.default.temporaryDirectory
                .appending(path: "zapfast-debug-export-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let started = Date()
            model.exportChat(model.sidebarOrder[index], includeMedia: media, into: parent) { result in
                defer { try? FileManager.default.removeItem(at: parent) }
                switch result {
                case .success(let summary):
                    let pages = (try? FileManager.default.contentsOfDirectory(atPath: summary.folder.path(percentEncoded: false)))?
                        .filter { $0.hasSuffix(".html") }.count ?? 0
                    let bytes = (try? summary.page.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(2)))
                    write(name, "messages=\(summary.messages) attachments=\(summary.attachments) missing=\(summary.missingMedia) pages=\(pages) firstPageBytes=\(bytes) seconds=\(seconds)")
                case .failure(let error):
                    write(name, "failed: \(type(of: error))")
                }
            }
        case "shot":
            // shot:popover captures the popover over the window instead.
            let target = parts.count > 1 ? parts[1] : ""
            write(name, shot(popover: target == "popover", other: target == "other", call: target == "call"))
        case "action":
            // action:<selector>, colons and all (`action:terminate:` quits).
            let selector = String(command.dropFirst("action:".count))
            guard !selector.isEmpty else { return }
            let sent = NSApp.sendAction(Selector(selector), to: nil, from: nil)
            write(name, "\(selector) sent: \(sent)")
        default:
            write("unknown", command)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.identifier?.rawValue != "chat" }
    }

    // MARK: Tree

    private static func tree() -> String {
        guard let window = mainWindow() else { return "no window" }
        var out = "window \(window.frame) content \(window.contentLayoutRect)\n"
        if let toolbar = window.toolbar {
            for item in toolbar.items {
                let frame = item.view.map { $0.convert($0.bounds, to: nil) } ?? .zero
                let glass = Selector(("glassBehavior"))
                typealias Getter = @convention(c) (AnyObject, Selector) -> Int
                let behavior = item.responds(to: glass) ? unsafeBitCast(item.method(for: glass), to: Getter.self)(item, glass) : -1
                let viewBehavior = item.view.map { $0.responds(to: glass) ? unsafeBitCast($0.method(for: glass), to: Getter.self)($0, glass) : -1 } ?? -2
                out += "toolbar \(item.itemIdentifier.rawValue) hidden=\(item.isHidden) view=\(frame) glass=\(behavior) viewGlass=\(viewBehavior)\n"
            }
        }
        if let frame = window.contentView?.superview {
            describe(frame, depth: 0, into: &out)
        }
        return out
    }

    private static func describe(_ view: NSView, depth: Int, into out: inout String) {
        guard depth < 40 else { return }
        let insets = view.safeAreaInsets
        let safe = insets.top + insets.left + insets.right + insets.bottom > 0
            ? " safe(t\(whole(insets.top)) l\(whole(insets.left)) r\(whole(insets.right)) b\(whole(insets.bottom)))" : ""
        let hidden = view.isHidden ? " hidden" : ""
        let name = NSStringFromClass(type(of: view)).components(separatedBy: ".").last ?? "?"
        out += String(repeating: "  ", count: depth) + "\(name) \(view.frame.integral)\(safe)\(hidden)\(pockets(of: view))\n"
        // Rows of tables are many and alike: their count is enough.
        if view is NSTableView {
            out += String(repeating: "  ", count: depth + 1) + "(\(view.subviews.count) row views)\n"
            return
        }
        for subview in view.subviews {
            describe(subview, depth: depth + 1, into: &out)
        }
    }

    /// How AppKit's scroll edge effect is set up on a scroll view or a
    /// title bar's background: private selectors, read when they answer.
    private static func pockets(of view: NSView) -> String {
        var parts: [String] = []
        func integer(_ name: String) -> Int? {
            let selector = Selector(name)
            guard view.responds(to: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int
            return unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector)
        }
        func integer(_ name: String, edge: Int) -> Int? {
            let selector = Selector(name)
            guard view.responds(to: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector, Int) -> Int
            return unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector, edge)
        }
        if view is NSScrollView {
            for name in ["_isRegisteredWithWindowSectionController", "relaxRegistrationRequirements", "computedHasScrolledContentsUnderTitlebar", "titlebarBackgroundStyle"] {
                if let value = integer(name) { parts.append("\(name.trimmingCharacters(in: CharacterSet(charactersIn: "_")))=\(value)") }
            }
            if let allowed = integer("allowedPocketEdges") { parts.append("allowed=\(allowed)") }
            if let shown = integer("alwaysShownPocketEdges") { parts.append("alwaysShown=\(shown)") }
            let styles = (0..<4).compactMap { edge in integer("scrollPocketStyleOnEdge:", edge: edge).map { "\(edge):\($0)" } }
            let registered = Selector(("_registeredPocketContainersOnEdge:"))
            if view.responds(to: registered) {
                typealias Getter = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
                let get = unsafeBitCast(view.method(for: registered), to: Getter.self)
                let counts = (0..<4).map { edge -> String in
                    let containers = get(view, registered, edge)?.takeUnretainedValue()
                    let names = (containers as? NSArray)?.compactMap { NSStringFromClass(type(of: $0 as AnyObject)).components(separatedBy: ".").last } ?? []
                    return "\(edge):\(names.joined(separator: ","))"
                }
                parts.append("containers[\(counts.joined(separator: " "))]")
            }
            if !styles.isEmpty { parts.append("styles[\(styles.joined(separator: " "))]") }
            let scroll = view as! NSScrollView
            parts.append("insets(t\(whole(scroll.contentInsets.top)) auto=\(scroll.automaticallyAdjustsContentInsets))")
        }
        if NSStringFromClass(type(of: view)) == "NSTitlebarBackgroundView" {
            if let style = integer("style") { parts.append("style=\(style)") }
            let pocket = Selector(("_scrollPocketIfExists"))
            if view.responds(to: pocket) {
                parts.append("pocket=\(view.perform(pocket)?.takeUnretainedValue() == nil ? "none" : "yes")")
            }
            parts.append("alpha=\(view.alphaValue)")
        }
        return parts.isEmpty ? "" : " {" + parts.joined(separator: " ") + "}"
    }

    /// Some views report insets of the largest number there is.
    private static func whole(_ value: CGFloat) -> String {
        abs(value) < 1e9 ? "\(Int(value))" : "∞"
    }

    // MARK: Resize

    private static func resize(steps: Int, points: Double) -> String {
        guard let window = mainWindow() else { return "no window" }
        let original = window.frame
        var times: [Double] = []
        for step in 0..<steps {
            let depth = step < steps / 2 ? step : steps - step
            var frame = original
            frame.size.width -= Double(depth) * points
            let start = CACurrentMediaTime()
            window.setFrame(frame, display: true)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.008))
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        window.setFrame(original, display: true)
        let sorted = times.sorted()
        let total = times.reduce(0, +)
        return String(
            format: "%d steps of %.0f pt: total %.0f ms, median %.0f, worst %.0f, over 100 ms %d\nsteps: %@",
            steps, points, total, sorted[sorted.count / 2], sorted.last ?? 0, times.count { $0 > 100 },
            times.map { String(format: "%.0f", $0) }.joined(separator: " ")
        )
    }

    // MARK: Timeline

    private static func scrollToTop(times: Int) async -> String {
        guard let content = mainWindow()?.contentView, let table = timeline(in: content),
              let scrollView = table.enclosingScrollView else { return "no timeline" }
        let before = table.numberOfRows
        for _ in 0..<times {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
            scrollView.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "rows \(before) -> \(table.numberOfRows)"
    }

    private static func timeline(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.identifier?.rawValue == "ZapFastMessageTimeline" { return table }
        for subview in view.subviews {
            if let found = timeline(in: subview) { return found }
        }
        return nil
    }

    // MARK: Shot

    /// A window of the app as the screen shows it, as PNG data.
    private static func capture(_ window: NSWindow) -> Data? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let grab = unsafeBitCast(symbol, to: Capture.self)
        guard let image = grab(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// `CGWindowListCreateImage`, which Swift no longer offers but the
    /// system still answers for the app's own windows.
    private static func shot(popover: Bool = false, other: Bool = false, call: Bool = false) -> String {
        let popoverWindow = NSApp.windows.last { NSStringFromClass(type(of: $0)).contains("Popover") && $0.isVisible }
        // Another titled window of the app, such as Settings.
        let otherWindow = NSApp.windows.last {
            $0.isVisible && $0.styleMask.contains(.titled) && (500...700).contains($0.frame.width)
        }
        let callWindow = NSApp.windows.last { $0 is NSPanel && $0.title == String(localized: "Call") && $0.isVisible }
        guard let window = call ? callWindow : popover ? popoverWindow : other ? otherWindow : mainWindow() else {
            return "no window"
        }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return "no capture" }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // Including only this window, at its own bounds, at the best resolution.
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() else {
            return "capture failed"
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no png" }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "ZapFastMac").appending(path: "debug")
        let file = call ? "call.png" : popover ? "popover.png" : other ? "other.png" : "shot.png"
        try? data.write(to: folder.appending(path: file))
        return "\(image.width)x\(image.height)"
    }

    // MARK: Output

    private static func write(_ name: String, _ text: String) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "ZapFastMac").appending(path: "debug")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text.write(to: folder.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
    }
}
#endif
