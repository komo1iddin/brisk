import CoreGraphics
import Foundation

/// What was done to a photo or video before sending it: how it is turned,
/// straightened, mirrored and cropped, what was drawn and written on it,
/// and for a video the part kept and whether its sound goes too.
///
/// Everything drawn lives on the *canvas*: the picture after its quarter
/// turns, straightening and mirroring, before the crop. Points are
/// fractions of the canvas (0…1 on each axis), sizes fractions of its
/// longer side, so they survive any output resolution and a quarter turn
/// only has to move them.
nonisolated public struct MediaEdit: Equatable, Sendable {
    /// Quarter turns counter-clockwise, 0…3.
    public var turns = 0
    /// Degrees counter-clockwise, within ±`maxStraighten`. The picture is
    /// enlarged just enough to keep the canvas covered.
    public var straighten: Double = 0
    /// Mirrored left to right, after turning and straightening.
    public var mirrored = false
    /// The part of the canvas that is sent.
    public var crop = MediaEdit.full
    public var strokes: [MediaStroke] = []
    public var overlays: [MediaOverlay] = []
    /// For a video: the seconds kept, `nil` for all of it.
    public var trim: ClosedRange<Double>?
    /// For a video: sent without its sound.
    public var muted = false

    public static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    public static let maxStraighten: Double = 45
    /// The crop never gets smaller than this share of the canvas.
    public static let minCrop: CGFloat = 0.05

    public init() {}

    /// Nothing was changed: the file can go as it is (at its quality).
    public var isEmpty: Bool { self == MediaEdit() }

    /// The picture itself changes (not only a video's trim or sound).
    public var changesPicture: Bool {
        turns != 0 || straighten != 0 || mirrored || crop != Self.full || !strokes.isEmpty || !overlays.isEmpty
    }

    public var hasGeometry: Bool {
        turns != 0 || straighten != 0 || mirrored || crop != Self.full
    }

    /// The canvas size for a source of `size` (its quarter turns applied).
    public func canvasSize(for size: CGSize) -> CGSize {
        turns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// The whole turn the picture is drawn at: quarter turns and
    /// straightening, in radians counter-clockwise.
    public var angle: Double {
        (Double(turns) * 90 + straighten) * .pi / 180
    }

    /// How much the turned picture is enlarged so that, straightened, it
    /// still covers a canvas of `canvas`.
    public static func coverScale(canvas: CGSize, straighten degrees: Double) -> CGFloat {
        guard degrees != 0, canvas.width > 0, canvas.height > 0 else { return 1 }
        let radians = abs(degrees) * .pi / 180
        let cosine = CGFloat(cos(radians)), sine = CGFloat(sin(radians))
        let width = canvas.width * cosine + canvas.height * sine
        let height = canvas.width * sine + canvas.height * cosine
        return max(width / canvas.width, height / canvas.height)
    }

    // MARK: Turning and mirroring

    /// Turns the canvas a quarter counter-clockwise, as it looks: the crop
    /// and everything drawn go round with it.
    public mutating func rotateLeft() {
        // Mirroring reverses the sense of a turn made under it.
        turns = (turns + (mirrored ? 3 : 1)) % 4
        crop = CGRect(x: crop.minY, y: 1 - crop.maxX, width: crop.height, height: crop.width)
        strokes = strokes.map { stroke in
            var stroke = stroke
            stroke.points = stroke.points.map { CGPoint(x: $0.y, y: 1 - $0.x) }
            return stroke
        }
        overlays = overlays.map { overlay in
            var overlay = overlay
            overlay.center = CGPoint(x: overlay.center.y, y: 1 - overlay.center.x)
            overlay.rotation -= .pi / 2
            return overlay
        }
    }

    /// Mirrors the canvas left to right. Drawings move with the picture;
    /// writing stays readable.
    public mutating func mirror() {
        mirrored.toggle()
        crop = CGRect(x: 1 - crop.maxX, y: crop.minY, width: crop.width, height: crop.height)
        strokes = strokes.map { stroke in
            var stroke = stroke
            stroke.points = stroke.points.map { CGPoint(x: 1 - $0.x, y: $0.y) }
            return stroke
        }
        overlays = overlays.map { overlay in
            var overlay = overlay
            overlay.center.x = 1 - overlay.center.x
            overlay.rotation = -overlay.rotation
            return overlay
        }
    }

    /// Straightening as it looks on screen (clockwise positive, like the
    /// dial), whichever way the canvas is mirrored.
    public var visibleStraighten: Double {
        get { mirrored ? straighten : -straighten }
        set {
            let clamped = min(max(newValue, -Self.maxStraighten), Self.maxStraighten)
            straighten = mirrored ? clamped : -clamped
        }
    }

    /// Back to the picture as it came; what was drawn goes back with it.
    public mutating func resetGeometry() {
        if mirrored { mirror() }
        while turns != 0 { rotateLeft() }
        straighten = 0
        crop = Self.full
    }

    // MARK: Crop

    /// A crop of `aspect` (width over height, in pixels) as large as fits
    /// the canvas, centred on the current one.
    public static func crop(aspect: CGFloat, canvas: CGSize, around current: CGRect) -> CGRect {
        guard aspect > 0, canvas.width > 0, canvas.height > 0 else { return full }
        // In canvas fractions a pixel aspect becomes this.
        let fractional = aspect * canvas.height / canvas.width
        var width: CGFloat = 1, height: CGFloat = 1
        if fractional > 1 { height = 1 / fractional } else { width = fractional }
        let center = CGPoint(x: current.midX, y: current.midY)
        let x = min(max(0, center.x - width / 2), 1 - width)
        let y = min(max(0, center.y - height / 2), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `rect` kept inside the canvas and no smaller than `minCrop`.
    public static func clamp(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, minCrop), 1)
        let height = min(max(rect.height, minCrop), 1)
        let x = min(max(0, rect.minX), 1 - width)
        let y = min(max(0, rect.minY), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A colour as the editor stores it: sRGB components.
nonisolated public struct MediaColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = MediaColor(red: 1, green: 1, blue: 1)
    public static let black = MediaColor(red: 0, green: 0, blue: 0)

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Relative luminance, to pick a readable colour against this one.
    public var isLight: Bool {
        0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.6
    }

    /// The colour at `position` (0 at the top, 1 at the bottom) of the
    /// editor's colour strip: white through grey to black, then the hues.
    public static func strip(_ position: Double) -> MediaColor {
        let position = min(max(position, 0), 1)
        let greys = 0.18
        if position <= greys {
            let value = 1 - position / greys
            return MediaColor(red: value, green: value, blue: value)
        }
        let hue = (position - greys) / (1 - greys) * 0.9
        return MediaColor(hue: hue)
    }

    init(hue: Double) {
        let sector = hue * 6
        let fraction = sector - floor(sector)
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (1, fraction, 0)
        case 1: (1 - fraction, 1, 0)
        case 2: (0, 1, fraction)
        case 3: (0, 1 - fraction, 1)
        case 4: (fraction, 0, 1)
        default: (1, 0, 1 - fraction)
        }
        self.init(red: red, green: green, blue: blue)
    }
}

/// A line drawn with one of the editor's brushes.
nonisolated public struct MediaStroke: Identifiable, Equatable, Sendable {
    public enum Brush: String, CaseIterable, Sendable {
        /// A fine line.
        case pen
        /// A bold line.
        case marker
        /// A wide, see-through line.
        case highlighter
        /// Hides what is under it in large squares: faces, numbers,
        /// addresses. Photos only.
        case pixelate

        /// Line width as a fraction of the canvas's longer side.
        public var width: Double {
            switch self {
            case .pen: 0.006
            case .marker: 0.016
            case .highlighter: 0.035
            case .pixelate: 0.05
            }
        }

        public var opacity: Double {
            self == .highlighter ? 0.45 : 1
        }
    }

    public let id: UUID
    public var brush: Brush
    public var color: MediaColor
    /// The width at which it was drawn: `brush.width` scaled by the zoom
    /// the canvas was seen at, so a line looks the same on screen.
    public var width: Double
    public var points: [CGPoint]

    public init(id: UUID = UUID(), brush: Brush, color: MediaColor, width: Double? = nil, points: [CGPoint]) {
        self.id = id
        self.brush = brush
        self.color = color
        self.width = width ?? brush.width
        self.points = points
    }

    /// The line through its points, smoothed through their midpoints, on
    /// a canvas of `size` (y down).
    public func path(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let scaled = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = scaled.first else { return path }
        path.move(to: first)
        if scaled.count == 1 {
            // A dot: a line of no length draws the round cap.
            path.addLine(to: first)
            return path
        }
        for index in 1..<scaled.count {
            let previous = scaled[index - 1], point = scaled[index]
            let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            if index == 1 {
                path.addLine(to: middle)
            } else {
                path.addQuadCurve(to: middle, control: previous)
            }
        }
        path.addLine(to: scaled[scaled.count - 1])
        return path
    }

    /// The width in points on a canvas of `size`.
    public func lineWidth(in size: CGSize) -> CGFloat {
        CGFloat(width) * max(size.width, size.height)
    }
}

/// Words or an emoji placed on the picture.
nonisolated public struct MediaOverlay: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(String)
        case emoji(String)
    }

    /// How writing is set, cycled by the editor's style button.
    public enum TextStyle: Int, CaseIterable, Sendable {
        /// Coloured letters with a soft shadow.
        case plain
        /// White or black letters on a coloured label.
        case label
        /// Coloured letters on a translucent dark label.
        case subtle
    }

    public enum Alignment: Int, CaseIterable, Sendable {
        case leading, center, trailing
    }

    public let id: UUID
    public var content: Content
    public var color: MediaColor
    public var style: TextStyle
    public var alignment: Alignment
    /// The centre, as a fraction of the canvas.
    public var center: CGPoint
    /// The font size as a fraction of the canvas's longer side.
    public var size: Double
    /// Radians clockwise, as the screen sees it.
    public var rotation: Double

    public init(
        id: UUID = UUID(),
        content: Content,
        color: MediaColor = .white,
        style: TextStyle = .plain,
        alignment: Alignment = .center,
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        size: Double = 0.06,
        rotation: Double = 0
    ) {
        self.id = id
        self.content = content
        self.color = color
        self.style = style
        self.alignment = alignment
        self.center = center
        self.size = size
        self.rotation = rotation
    }

    public var isEmpty: Bool {
        switch content {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .emoji(let emoji): emoji.isEmpty
        }
    }

    public static let sizes: ClosedRange<Double> = 0.02...0.4
}

/// How large a photo or video goes out, as WhatsApp offers it.
nonisolated public enum MediaQuality: String, CaseIterable, Sendable {
    /// Smaller and quicker to send.
    case standard
    /// Clearer, and several times larger.
    case hd

    /// The longest side of a photo sent at this quality.
    public var photoSide: Int {
        switch self {
        case .standard: 1600
        case .hd: 4096
        }
    }

    public var jpegQuality: Double {
        switch self {
        case .standard: 0.8
        case .hd: 0.92
        }
    }
}
