import AppKit

/// The quick reactions in a capsule of their own above a message's menu,
/// as Telegram shows them, instead of a React submenu inside it.
///
/// While a menu tracks, AppKit takes every event for the menu, and a
/// click outside it closes the menu without reaching another window. So
/// the bar watches the pointer instead: a timer in the common modes (which
/// run during tracking) reads where it is and whether the button is down,
/// lifts the emoji under it, and picks the one a click lands on, whether
/// the menu closes on that press or not. The bar is placed once the menu's
/// window is up, above it (below it when the screen has no room).
@MainActor
final class MenuReactionBar {
    /// The emoji offered, ours (if any) drawn picked.
    let emojis: [String]
    let mine: String?
    private let onPick: (String) -> Void
    private let onMore: () -> Void

    private let panel: NSPanel
    private let bar: ReactionBarView
    private weak var menu: NSMenu?
    private var timer: Timer?
    private var placed = false
    private var buttonWasDown = false
    /// The slot a press went down on, picked when it comes up there.
    private var pressed: Int?
    private var menuOpen = true
    private var finished = false
    private var closedAt: Date?

    init(emojis: [String], mine: String?, accent: NSColor, onPick: @escaping (String) -> Void, onMore: @escaping () -> Void) {
        self.emojis = emojis
        self.mine = mine
        self.onPick = onPick
        self.onMore = onMore
        bar = ReactionBarView(emojis: emojis, mine: mine, accent: accent)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: bar.frame.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = bar
        bar.onClick = { [weak self] slot in self?.pick(slot) }
    }

    /// The menu began tracking: watch the pointer until it is placed and
    /// picked from, or the menu closes.
    func menuOpened(_ menu: NSMenu) {
        self.menu = menu
        // The timer keeps the bar alive until it is dismissed: the menu's
        // session lets go of it as the menu closes, with a press pending.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The menu closed. A press that closed it may still come up on an
    /// emoji, so while the pointer is on the bar it stays for that press,
    /// briefly.
    func menuClosed() {
        menuOpen = false
        closedAt = Date()
        let slot = slot(under: NSEvent.mouseLocation)
        if NSEvent.pressedMouseButtons & 1 != 0, let slot { pressed = pressed ?? slot }
        if pressed == nil, slot == nil { dismiss() }
    }

    func dismiss() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        guard panel.isVisible else { return }
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func tick() {
        if !placed { place() }
        guard placed else { return }
        let location = NSEvent.mouseLocation
        let slot = slot(under: location)
        bar.hovered = slot
        let down = NSEvent.pressedMouseButtons & 1 != 0
        defer { buttonWasDown = down }
        if down, !buttonWasDown {
            pressed = slot
        } else if !down, buttonWasDown || pressed != nil {
            let target = pressed
            pressed = nil
            if let target, target == slot {
                pick(target)
                return
            }
        }
        // After the menu closed, the bar waits only for a press on it.
        if !menuOpen {
            let waited = Date().timeIntervalSince(closedAt ?? .distantPast)
            if pressed == nil ? slot == nil || waited > 0.4 : waited > 2 { dismiss() }
        }
    }

    private func slot(under location: NSPoint) -> Int? {
        guard placed, panel.frame.contains(location) else { return nil }
        let point = bar.convert(panel.convertPoint(fromScreen: location), from: nil)
        return bar.slot(at: point)
    }

    private func pick(_ slot: Int) {
        guard !finished else { return }
        let emoji = slot < emojis.count ? emojis[slot] : nil
        bar.flash(slot)
        menu?.cancelTracking()
        dismiss()
        // After the menu has gone, as its own items act.
        DispatchQueue.main.async { [onPick, onMore] in
            if let emoji { onPick(emoji) } else { onMore() }
        }
    }

    /// Above the menu's window, its leading edge on the menu's, kept on
    /// screen; below the menu when there is no room above.
    private func place() {
        guard let menuWindow = NSApp.windows.first(where: Self.isMenuWindow) else { return }
        let menuFrame = menuWindow.frame
        let screen = (menuWindow.screen ?? NSScreen.main)?.visibleFrame ?? menuFrame
        let size = bar.frame.size
        let gap: CGFloat = 6
        var origin = NSPoint(x: menuFrame.minX, y: menuFrame.maxY + gap)
        var above = true
        if origin.y + size.height > screen.maxY {
            origin.y = menuFrame.minY - gap - size.height
            above = false
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        placed = true
        bar.appear(fromBelow: above)
    }

    private static func isMenuWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.level == .popUpMenu
            && String(describing: type(of: window)).contains("Menu")
    }
}

/// The capsule: one slot per emoji and a + for the full picker.
final class ReactionBarView: NSView {
    var onClick: (Int) -> Void = { _ in }
    var hovered: Int? {
        didSet { if hovered != oldValue { lift(hovered, from: oldValue) } }
    }

    private let emojis: [String]
    private let mine: String?
    private let accent: NSColor
    private var slots: [CALayer] = []
    private let picked = CALayer()
    private let content = CALayer()

    static let slot: CGFloat = 36
    static let height: CGFloat = 44
    static let padding: CGFloat = 4

    init(emojis: [String], mine: String?, accent: NSColor) {
        self.emojis = emojis
        self.mine = mine
        self.accent = accent
        let count = CGFloat(emojis.count + 1)
        super.init(frame: NSRect(x: 0, y: 0, width: count * Self.slot + Self.padding * 2, height: Self.height))
        wantsLayer = true
        let background = Self.background(frame: bounds)
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        let host = NSView(frame: bounds)
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        content.frame = host.bounds
        host.layer?.addSublayer(content)
        picked.isHidden = true
        content.addSublayer(picked)
        for index in 0...emojis.count {
            let layer = CALayer()
            layer.frame = slotFrame(index).insetBy(dx: 2, dy: 2)
            layer.contentsGravity = .center
            content.addSublayer(layer)
            slots.append(layer)
        }
        if let mine, let index = emojis.firstIndex(of: mine) {
            picked.isHidden = false
            picked.frame = slotFrame(index).insetBy(dx: 1, dy: 1)
            picked.cornerRadius = picked.frame.height / 2
        }
        drawSlots()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "React"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Glass on macOS 26, the menu's material before it.
    private static func background(frame: NSRect) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = frame.height / 2
            return glass
        }
        let material = NSVisualEffectView(frame: frame)
        material.material = .menu
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = frame.height / 2
        material.layer?.masksToBounds = true
        return material
    }

    private func slotFrame(_ index: Int) -> CGRect {
        CGRect(
            x: Self.padding + CGFloat(index) * Self.slot,
            y: (Self.height - Self.slot) / 2,
            width: Self.slot, height: Self.slot
        )
    }

    /// The slot under `point`, in this view's coordinates.
    func slot(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let index = Int((point.x - Self.padding) / Self.slot)
        return (0...emojis.count).contains(index) ? index : nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawSlots()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawSlots()
    }

    private func drawSlots() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            picked.backgroundColor = accent.withAlphaComponent(0.22).cgColor
            for (index, layer) in slots.enumerated() {
                layer.contentsScale = scale
                let image = index < emojis.count
                    ? Self.emojiImage(emojis[index])
                    : Self.plusImage()
                layer.contents = image?.layerContents(forContentsScale: scale)
            }
        }
    }

    private static func emojiImage(_ emoji: String) -> NSImage? {
        let string = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 24)])
        let size = string.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
            string.draw(at: .zero)
            return true
        }
    }

    private static func plusImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "More Reactions"))?
            .withSymbolConfiguration(configuration)
        guard let symbol else { return nil }
        // A faint disc behind the +, as a button.
        let side: CGFloat = 28
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let size = symbol.size
            symbol.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            return true
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The capsule grows out of the menu's edge, the emoji popping in one
    /// after another.
    func appear(fromBelow: Bool) {
        guard !reduceMotion else { return }
        let now = CACurrentMediaTime()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        layer?.add(fade, forKey: "appear")
        for (index, slot) in slots.enumerated() {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.4
            pop.toValue = 1
            pop.mass = 1
            pop.stiffness = 420
            pop.damping = 20
            pop.duration = pop.settlingDuration
            pop.beginTime = now + Double(index) * 0.018
            pop.fillMode = .backwards
            slot.add(pop, forKey: "pop")
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0
            show.toValue = 1
            show.duration = 0.1
            show.beginTime = pop.beginTime
            show.fillMode = .backwards
            slot.add(show, forKey: "show")
        }
        let move = CASpringAnimation(keyPath: "position.y")
        move.fromValue = fromBelow ? -6 : 6
        move.toValue = 0
        move.stiffness = 300
        move.damping = 22
        move.duration = move.settlingDuration
        move.isAdditive = true
        layer?.add(move, forKey: "rise")
    }

    /// The emoji under the pointer grows; the one it left settles back.
    private func lift(_ index: Int?, from old: Int?) {
        for (target, scale) in [(old, 1.0), (index, 1.28)] {
            guard let target, slots.indices.contains(target) else { continue }
            let slot = slots[target]
            let from = slot.presentation()?.value(forKeyPath: "transform.scale") ?? 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slot.setValue(scale, forKeyPath: "transform.scale")
            CATransaction.commit()
            guard !reduceMotion else { continue }
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = from
            spring.toValue = scale
            spring.stiffness = 500
            spring.damping = 24
            spring.duration = spring.settlingDuration
            slot.add(spring, forKey: "lift")
        }
    }

    /// The picked emoji gives a little bounce as the bar goes.
    func flash(_ index: Int) {
        guard slots.indices.contains(index), !reduceMotion else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.28, 1.5, 1.2]
        bounce.duration = 0.12
        slots[index].add(bounce, forKey: "flash")
    }

    // After the menu closed, a click arrives as usual.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if let index = slot(at: convert(event.locationInWindow, from: nil)) { onClick(index) }
    }
}
