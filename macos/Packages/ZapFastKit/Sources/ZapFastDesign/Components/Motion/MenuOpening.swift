import AppKit
import QuartzCore

/// How the app's menus arrive: each grows out of the point it was opened
/// from, with a little spring, instead of being there at once.
///
/// The menus are AppKit's own, every one of them drawn in a window of this
/// process: a message's, a chat's, the toolbar's pull-downs, SwiftUI's
/// context menus. The glass is that window's content view, so scaling the
/// view's layer scales the whole menu. The window's shadow does not scale
/// with it: the window server casts it from the full window. So while the
/// menu grows its own shadow is off, and a copy of it (`MenuShadow`), in a
/// window just below the menu, grows with the same spring; once the menu
/// has settled the real shadow comes back and the copy goes.
///
/// The window is made while the menu sets up, before it tracks, and is
/// taken as soon as the menu's run loop starts (an observer there runs
/// before anything of it is drawn), hidden by its alpha until the layer
/// holds its animation. A tracking menu draws nothing, so that animation
/// is sent to the render server at once; a timer in the common modes,
/// which run while a menu tracks, hands the shadow back. The menu bar's
/// menus are left as the system shows them.
@MainActor
public final class MenuOpening {
    /// The size a menu starts at, and its spring: a third of a second,
    /// with the slightest overshoot.
    static let from: CGFloat = 0.55
    static let response: TimeInterval = 0.32
    static let bounce: CGFloat = 0.12
    static let fade: TimeInterval = 0.12
    /// How long to wait for a menu's window, and for its spring at most.
    private static let patience: TimeInterval = 0.4
    private static let longest: TimeInterval = 0.8
    private static let key = "zapfast.menuOpening"

    /// Settings can turn it off; the menus then open as the system shows
    /// them.
    public static var isEnabled = true

    private static var observer: NSObjectProtocol?
    /// The one menu being opened: a second menu replaces it.
    private static var opening: MenuOpening?
    private static var shadow: MenuShadow?

    private let pointer: NSPoint
    /// Menus already up when this one began, such as the one a submenu
    /// hangs from.
    private let earlier: Set<ObjectIdentifier>
    private let started = CACurrentMediaTime()
    private var runLoopObserver: CFRunLoopObserver?
    private var timer: Timer?
    private weak var window: NSWindow?
    private weak var layer: CALayer?
    private var shadowed = false
    private var caughtAt: CFTimeInterval?
    private var shown = false

    private init(pointer: NSPoint) {
        self.pointer = pointer
        earlier = Set(Self.menuWindows().map(ObjectIdentifier.init))
    }

    /// Grows every menu the app opens from now on.
    public static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { notification in
            // Posted on the main thread as the menu begins, and handled
            // there at once: the window is not made yet.
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, !isInMenuBar(menu) else { return }
                play(from: NSEvent.mouseLocation)
            }
        }
    }

    /// Grow the menu that is about to open from `pointer`, a point on the
    /// screen (where the click was).
    /// Only macOS 26's glass menus are grown: the shadow is measured
    /// against theirs.
    public static func play(from pointer: NSPoint) {
        guard #available(macOS 26, *), isEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        opening?.finish()
        let opening = MenuOpening(pointer: pointer)
        Self.opening = opening
        opening.watch()
    }

    /// The frontmost menu's window, which a message's reactions are placed
    /// against.
    public static func menuWindow() -> NSWindow? {
        menuWindows().first
    }

    private static func menuWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && window.level == .popUpMenu
                && String(describing: type(of: window)).contains("Menu")
        }
    }

    private static func isInMenuBar(_ menu: NSMenu) -> Bool {
        guard let bar = NSApp.mainMenu else { return false }
        var menu: NSMenu? = menu
        while let current = menu {
            if current === bar { return true }
            menu = current.supermenu
        }
        return false
    }

    private func watch() {
        let activities: CFRunLoopActivity = [.entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, -2_000_000) { _, _ in
            MainActor.assumeIsolated { Self.opening?.catchWindow() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObserver = observer
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { Self.opening?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Takes the new menu's window before it is first shown.
    private func catchWindow() {
        guard caughtAt == nil else { return }
        guard let window = Self.menuWindows().first(where: { !earlier.contains(ObjectIdentifier($0)) }) else {
            if CACurrentMediaTime() - started > Self.patience { finish() }
            return
        }
        stopObserving()
        guard let view = window.contentView else { return finish() }
        view.wantsLayer = true
        guard let layer = view.layer, layer.animation(forKey: Self.key) == nil,
              layer.bounds.width > 1, layer.bounds.height > 1 else { return finish() }
        window.alphaValue = 0
        self.window = window
        self.layer = layer
        caughtAt = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let point = Self.pivot(
            pointer: pointer, in: window.frame, size: layer.bounds.size,
            flipped: view.isFlipped, anchor: layer.anchorPoint
        )
        Self.grow(layer, about: point)
        if window.hasShadow {
            window.hasShadow = false
            shadowed = true
            let shadow = Self.shadow ?? MenuShadow()
            Self.shadow = shadow
            let radius = Self.cornerRadius(of: view)
            let copy = shadow.show(below: window, radius: radius)
            let point = Self.pivot(
                pointer: pointer, in: window.frame, size: copy.bounds.size,
                flipped: false, anchor: copy.anchorPoint
            )
            Self.grow(copy, about: point)
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    private static func cornerRadius(of view: NSView) -> CGFloat {
        if #available(macOS 26, *), let glass = view as? NSGlassEffectView { return glass.cornerRadius }
        return 12
    }

    /// The spring and the fade, the same for the menu and its shadow.
    private static func grow(_ layer: CALayer, about point: CGPoint) {
        let grow = CASpringAnimation(perceptualDuration: response, bounce: bounce)
        grow.keyPath = "transform"
        grow.fromValue = NSValue(caTransform3D: scaling(from, about: point))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: key)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: key + ".fade")
    }

    private func step() {
        guard let caughtAt else { return catchWindow() }
        // A menu closed while it grew takes its shadow with it.
        guard let window, window.isVisible else { return finish() }
        // The layer holds its animation by now: the window shows it.
        if !shown {
            window.alphaValue = 1
            shown = true
        }
        let elapsed = CACurrentMediaTime() - caughtAt
        let scale = layer?.presentation()?.transform.m11 ?? 1
        if (elapsed > Self.fade && abs(scale - 1) < 0.002) || elapsed > Self.longest { finish() }
    }

    private func stopObserving() {
        if let runLoopObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes) }
        runLoopObserver = nil
    }

    private func finish() {
        stopObserving()
        timer?.invalidate()
        timer = nil
        if let window {
            window.alphaValue = 1
            if shadowed {
                window.hasShadow = true
                window.invalidateShadow()
            }
        }
        if shadowed { Self.shadow?.hide() }
        window = nil
        if Self.opening === self { Self.opening = nil }
    }

    /// What a menu grows around: the pointer, in its layer's own
    /// coordinates, kept inside a menu that was moved to fit the screen or
    /// hangs below a button, and taken from the layer's anchor point.
    public static func pivot(
        pointer: NSPoint, in frame: NSRect, size: CGSize, flipped: Bool, anchor: CGPoint
    ) -> CGPoint {
        var point = CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
        if flipped { point.y = size.height - point.y }
        return CGPoint(
            x: min(max(point.x, 0), size.width) - anchor.x * size.width,
            y: min(max(point.y, 0), size.height) - anchor.y * size.height
        )
    }

    /// Scaling that leaves `point` where it is.
    public static func scaling(_ scale: CGFloat, about point: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(point.x, point.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -point.x, -point.y, 0)
    }
}

/// A menu's shadow, drawn the way the window server draws it, so that it
/// can grow with the menu: a soft shadow a little below, and a thin rim
/// (darker on a dark menu). The figures were measured against the real
/// shadow, pixel by pixel, on macOS 26, so the hand-over at the end shows
/// nothing. It sits in a window of its own just below the menu's, larger
/// than the menu by what the shadow spreads, and is cut away under the
/// glass, which would otherwise show it through.
@MainActor
final class MenuShadow {
    static let spread: CGFloat = 40
    static let blur: CGFloat = 8
    static let drop: CGFloat = 4
    static func opacity(dark: Bool) -> Float { dark ? 0.3 : 0.25 }
    static func rimOpacity(dark: Bool) -> CGFloat { dark ? 0.85 : 0.19 }

    private let window: NSWindow
    /// The menu's own shape: what is scaled, with the shadow and the rim
    /// drawn around it.
    private let shape = CALayer()
    private let soft = CALayer()
    private let rim = CAShapeLayer()
    private let cutout = CAShapeLayer()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        let view = NSView()
        view.layer = CALayer()
        view.wantsLayer = true
        window.contentView = view

        shape.anchorPoint = .zero
        soft.shadowColor = NSColor.black.cgColor
        soft.shadowRadius = Self.blur
        soft.shadowOffset = CGSize(width: 0, height: -Self.drop)
        rim.fillColor = nil
        rim.lineWidth = 0.5
        cutout.fillRule = .evenOdd
        shape.addSublayer(soft)
        shape.addSublayer(rim)
        shape.mask = cutout
        view.layer?.addSublayer(shape)
    }

    /// Puts the shadow below `menu`, at its full size, and returns the layer
    /// to grow.
    func show(below menu: NSWindow, radius: CGFloat) -> CALayer {
        let dark = menu.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        soft.shadowOpacity = Self.opacity(dark: dark)
        rim.strokeColor = NSColor.black.withAlphaComponent(Self.rimOpacity(dark: dark)).cgColor
        let size = menu.frame.size
        let bounds = CGRect(origin: .zero, size: size)
        let outline = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        window.setFrame(menu.frame.insetBy(dx: -Self.spread, dy: -Self.spread), display: false)
        shape.bounds = bounds
        shape.position = CGPoint(x: Self.spread, y: Self.spread)
        soft.frame = bounds
        soft.shadowPath = outline
        rim.frame = bounds
        let edge = bounds.insetBy(dx: -0.25, dy: -0.25)
        rim.path = CGPath(roundedRect: edge, cornerWidth: radius + 0.25, cornerHeight: radius + 0.25, transform: nil)
        let around = CGMutablePath()
        around.addRect(bounds.insetBy(dx: -Self.spread, dy: -Self.spread))
        around.addPath(outline)
        cutout.frame = bounds
        cutout.path = around
        window.order(.below, relativeTo: menu.windowNumber)
        return shape
    }

    func hide() {
        shape.removeAllAnimations()
        window.orderOut(nil)
    }
}
