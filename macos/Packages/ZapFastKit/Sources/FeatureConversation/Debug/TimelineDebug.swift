#if DEBUG
import AppKit
import ZapFastBridge
import ZapFastCore

/// Development aid for `DebugCommands`: acts on the bubbles on screen and
/// reports where they are, never what they say.
public enum TimelineDebug {
    /// The `n`th message on screen counted from the bottom, as a bubble cell
    /// and the frame of its bubble in screen coordinates.
    @MainActor
    private static func bubble(in table: NSTableView, fromBottom n: Int) -> (cell: BubbleCell, screen: CGRect)? {
        guard let window = table.window, let controller = table.dataSource as? TimelineController else { return nil }
        var found: [(BubbleCell, CGRect)] = []
        controller.forEachBubbleCell { cell in
            guard let layout = cell.bubbleLayout, cell.messageID != nil else { return }
            let inCell = layout.bubbleFrame(rowWidth: cell.bounds.width)
            let inWindow = cell.convert(inCell, to: nil)
            found.append((cell, window.convertToScreen(inWindow)))
        }
        found.sort { $0.1.minY < $1.1.minY }
        guard found.indices.contains(n) else { return nil }
        return found[n]
    }

    /// Opens the reaction picker on the `n`th message from the bottom.
    @MainActor
    public static func react(in table: NSTableView, model: AppModel, fromBottom n: Int) -> String {
        guard let (cell, screen) = bubble(in: table, fromBottom: n), let id = cell.messageID,
              let chat = model.selectedChatID else { return "no bubble" }
        model.reactionTarget = MessageKey(chat: chat, message: id)
        return "bubble at \(screen.integral)"
    }

    /// Opens the menu of the `n`th message from the bottom, as a
    /// right-click does; `during` runs while it tracks. Returns once it closed.
    @MainActor
    public static func menu(in table: NSTableView, fromBottom n: Int, during: @escaping (NSMenu) -> Void) -> String {
        guard let (cell, screen) = bubble(in: table, fromBottom: n), let id = cell.messageID,
              let menu = cell.delegate?.menu(forMessage: id, selection: nil) else { return "no bubble" }
        nonisolated(unsafe) let (shown, during) = (menu, during)
        let timer = Timer(timeInterval: 0.9, repeats: false) { _ in
            MainActor.assumeIsolated { during(shown) }
        }
        RunLoop.main.add(timer, forMode: .common)
        let point = NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)
        menu.popUp(positioning: nil, at: point, in: cell)
        return "bubble at \(screen.integral)"
    }

    /// Clicks the sender's photo of the `n`th message from the bottom.
    @MainActor
    public static func sender(in table: NSTableView, fromBottom n: Int) -> String {
        guard let (cell, screen) = bubble(in: table, fromBottom: n) else { return "no bubble" }
        cell.debugClickSender()
        return "bubble at \(screen.integral)"
    }
}
#endif
