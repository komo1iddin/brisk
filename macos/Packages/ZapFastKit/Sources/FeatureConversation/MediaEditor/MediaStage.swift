import AppKit
import AVFoundation
import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Where the canvas sits in the stage. Browsing and drawing fit the crop
/// to the stage; cropping fits the whole canvas, so the crop can grow.
/// Moving between the two animates the zoom.
struct StageLayout: Equatable {
    /// The whole canvas, on screen.
    let canvas: CGRect
    /// The part of it that shows (the crop, or all of it while cropping).
    let visible: CGRect
    /// The crop, on screen.
    let crop: CGRect

    init(bounds: CGRect, picture: CGSize, crop: CGRect, cropping: Bool) {
        let side = CGSize(width: max(picture.width, 1), height: max(picture.height, 1))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if cropping {
            let scale = min(bounds.width / side.width, bounds.height / side.height)
            let size = CGSize(width: side.width * scale, height: side.height * scale)
            canvas = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            visible = canvas
        } else {
            let cropped = CGSize(width: side.width * crop.width, height: side.height * crop.height)
            let scale = min(bounds.width / cropped.width, bounds.height / cropped.height)
            let shown = CGSize(width: cropped.width * scale, height: cropped.height * scale)
            visible = CGRect(x: center.x - shown.width / 2, y: center.y - shown.height / 2, width: shown.width, height: shown.height)
            let size = CGSize(width: side.width * scale, height: side.height * scale)
            canvas = CGRect(
                x: visible.minX - crop.minX * size.width, y: visible.minY - crop.minY * size.height,
                width: size.width, height: size.height
            )
        }
        self.crop = CGRect(
            x: canvas.minX + crop.minX * canvas.width, y: canvas.minY + crop.minY * canvas.height,
            width: crop.width * canvas.width, height: crop.height * canvas.height
        )
    }

    /// A point on screen as a fraction of the canvas.
    func fraction(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - canvas.minX) / max(canvas.width, 1), y: (point.y - canvas.minY) / max(canvas.height, 1))
    }
}

/// The picture or video with everything drawn on it, and the tools'
/// gestures: drawing, moving and sizing words and emoji, cropping.
struct MediaStage: View {
    let attachment: Attachment
    let state: MediaEditorState
    /// Starts an undoable change (saves the edit as it is now).
    let begin: () -> Void
    /// Changes the edit without another undo step.
    let update: (MediaEdit) -> Void
    /// Opens a text overlay for rewriting.
    let rewrite: (MediaOverlay) -> Void

    @State private var liveStroke: MediaStroke?
    @State private var overlayStart: MediaOverlay?
    /// The overlay being moved, sized or turned, drawn from here until the
    /// gesture ends and it goes back to the edit in one step: a round trip
    /// through the model on every event made the drag stutter.
    @State private var liveOverlay: MediaOverlay?
    /// Quarter turns counted without wrapping, so a fourth turn goes on
    /// round instead of spinning back.
    @State private var spin: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var edit: MediaEdit { attachment.edit }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            if let source = sourceSize {
                let picture = edit.canvasSize(for: source)
                let cropping = state.mode == .crop
                let area = cropping ? bounds.insetBy(dx: 28, dy: 28) : bounds
                let layout = StageLayout(bounds: area, picture: picture, crop: edit.crop, cropping: cropping)
                ZStack(alignment: .topLeading) {
                    canvas(layout: layout, source: source)
                        .frame(width: layout.canvas.width, height: layout.canvas.height)
                        .mask(alignment: .topLeading) {
                            Rectangle()
                                .frame(width: layout.visible.width, height: layout.visible.height)
                                .offset(x: layout.visible.minX - layout.canvas.minX, y: layout.visible.minY - layout.canvas.minY)
                        }
                        .offset(x: layout.canvas.minX, y: layout.canvas.minY)
                    if cropping {
                        CropFrame(
                            layout: layout,
                            aspect: state.aspect.value(source: picture, portrait: state.portrait),
                            picture: picture,
                            current: edit.crop,
                            begin: begin,
                            change: { crop in var edit = edit; edit.crop = crop; update(edit) }
                        )
                        .transition(.opacity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .coordinateSpace(.named(MediaStage.space))
                .animation(.zf(reduceMotion, duration: 0.3), value: cropping)
                .animation(.zf(reduceMotion, duration: 0.25), value: spin)
                .animation(.zf(reduceMotion, duration: 0.25), value: edit.mirrored)
                .onChange(of: edit.turns) { old, new in followTurns(from: old, to: new) }
                .onChange(of: max(layout.canvas.width, layout.canvas.height), initial: true) { _, side in
                    if !cropping { state.displayLongSide = side }
                }
            } else if attachment.media == .none {
                DocumentCard(attachment: attachment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    static let space = "media-stage"

    /// Follows the quarter turns the short way round.
    private func followTurns(from old: Int, to new: Int) {
        let step = (new - old + 4) % 4
        spin = (spin ?? old) + (step == 3 ? -1 : step)
    }

    /// The source's upright size once it is loaded.
    private var sourceSize: CGSize? {
        switch attachment.media {
        case .photo: state.photos[attachment.id]?.size
        case .video: state.videos[attachment.id]?.info.size
        case .none: nil
        }
    }

    // MARK: Canvas

    private func canvas(layout: StageLayout, source: CGSize) -> some View {
        let size = layout.canvas.size
        return ZStack(alignment: .topLeading) {
            picture(size: size, source: source, image: state.photos[attachment.id]?.image)
            if let pixelated = state.photos[attachment.id]?.pixelated, !pixelateStrokes.isEmpty {
                picture(size: size, source: source, image: pixelated)
                    .mask {
                        Canvas { context, size in
                            for stroke in pixelateStrokes {
                                context.stroke(
                                    Path(stroke.path(in: size)), with: .color(.black),
                                    style: StrokeStyle(lineWidth: stroke.lineWidth(in: size), lineCap: .round, lineJoin: .round)
                                )
                            }
                        }
                    }
            }
            Canvas { context, size in
                for stroke in inkStrokes {
                    context.drawLayer { layer in
                        layer.opacity = stroke.brush.opacity
                        layer.stroke(
                            Path(stroke.path(in: size)), with: .color(Color(stroke.color)),
                            style: StrokeStyle(lineWidth: stroke.lineWidth(in: size), lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }
            .allowsHitTesting(false)

            overlays(size: size, layout: layout)
        }
        .frame(width: size.width, height: size.height)
        // Only the part that shows takes clicks: a cropped canvas reaches
        // past it, under the bars around the stage.
        .contentShape(LocalRect(rect: layout.visible.offsetBy(dx: -layout.canvas.minX, dy: -layout.canvas.minY)))
        .gesture(drawing(layout: layout), including: state.mode == .draw ? .all : .subviews)
        .onTapGesture {
            // A click beside the overlays lets go of the one picked.
            if state.mode == .browse { state.selectedOverlay = nil }
        }
    }

    /// The source turned, straightened, enlarged to cover and mirrored, as
    /// `MediaExport.drawPicture` draws it.
    @ViewBuilder
    private func picture(size: CGSize, source: CGSize, image: CGImage?) -> some View {
        let native = edit.canvasSize(for: source)
        let scale = size.width / max(native.width, 1)
        let cover = MediaEdit.coverScale(canvas: size, straighten: edit.straighten)
        let drawn = CGSize(width: source.width * scale * cover, height: source.height * scale * cover)
        Group {
            if attachment.media == .video, let video = state.videos[attachment.id] {
                VideoSurface(player: video.player)
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        .rotationEffect(.degrees(-(Double(spin ?? edit.turns) * 90 + edit.straighten)))
        .scaleEffect(x: edit.mirrored ? -1 : 1, y: 1)
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }

    private var allStrokes: [MediaStroke] {
        edit.strokes + (liveStroke.map { [$0] } ?? [])
    }

    private var pixelateStrokes: [MediaStroke] {
        allStrokes.filter { $0.brush == .pixelate }
    }

    private var inkStrokes: [MediaStroke] {
        allStrokes.filter { $0.brush != .pixelate }
    }

    // MARK: Drawing

    private func drawing(layout: StageLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MediaStage.space))
            .onChanged { value in
                let point = layout.fraction(value.location)
                if var stroke = liveStroke {
                    // Skip points closer than a pixel and a half on screen.
                    if let last = stroke.points.last,
                       hypot((point.x - last.x) * layout.canvas.width, (point.y - last.y) * layout.canvas.height) < 1.5 {
                        return
                    }
                    stroke.points.append(point)
                    liveStroke = stroke
                } else {
                    // A line looks as thick on screen however far in the
                    // crop has zoomed.
                    let zoom = max(layout.visible.width, layout.visible.height) / max(layout.canvas.width, layout.canvas.height)
                    liveStroke = MediaStroke(
                        brush: state.brush, color: state.drawColor,
                        width: state.brush.width * Double(zoom), points: [point]
                    )
                }
            }
            .onEnded { _ in
                guard let stroke = liveStroke else { return }
                begin()
                var edit = edit
                edit.strokes.append(stroke)
                update(edit)
                liveStroke = nil
            }
    }

    // MARK: Overlays

    private func overlays(size: CGSize, layout: StageLayout) -> some View {
        let long = max(size.width, size.height)
        return ForEach(edit.overlays) { stored in
            let overlay = liveOverlay?.id == stored.id ? liveOverlay! : stored
            let hidden = state.mode == .text && !state.draftIsNew && state.draftText?.id == overlay.id
            let selected = state.selectedOverlay == overlay.id && state.mode == .browse
            OverlayLabel(overlay: overlay, fontSize: CGFloat(overlay.size) * long)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .shadow(color: .black.opacity(0.4), radius: 1)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        OverlayHandle(overlay: overlay, layout: layout, begin: { _ = beginOverlay($0) }, change: replace, end: endOverlay)
                            .offset(x: 11, y: 11)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selected {
                        Button {
                            begin()
                            var edit = edit
                            edit.overlays.removeAll { $0.id == overlay.id }
                            update(edit)
                            state.selectedOverlay = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(.white, in: .circle)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: -10, y: -10)
                        .help("Remove")
                    }
                }
                .contentShape(.rect)
                .rotationEffect(.radians(overlay.rotation))
                .scaleEffect(overlayStart?.id == overlay.id ? 1.04 : 1)
                .animation(.snappy(duration: 0.15), value: overlayStart?.id == overlay.id)
                .gesture(move(overlay, size: size))
                .simultaneousGesture(pinch(overlay))
                .simultaneousGesture(turn(overlay))
                .onTapGesture(count: 2) {
                    if case .text = overlay.content { rewrite(overlay) }
                }
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.15)) { state.selectedOverlay = overlay.id }
                }
                .position(x: overlay.center.x * size.width, y: overlay.center.y * size.height)
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(state.mode == .browse)
                .accessibilityLabel(accessibilityLabel(overlay))
        }
    }

    private func accessibilityLabel(_ overlay: MediaOverlay) -> Text {
        switch overlay.content {
        case .text(let text): Text(verbatim: text)
        case .emoji(let emoji): Text(verbatim: emoji)
        }
    }

    /// The overlay as a gesture found it; the first call of a gesture
    /// saves the edit for undo.
    private func beginOverlay(_ overlay: MediaOverlay) -> MediaOverlay {
        if let overlayStart { return overlayStart }
        overlayStart = overlay
        begin()
        state.selectedOverlay = overlay.id
        return overlay
    }

    /// Puts the overlay back into the edit once its gesture is over.
    private func endOverlay() {
        overlayStart = nil
        guard let overlay = liveOverlay else { return }
        liveOverlay = nil
        var edit = edit
        guard let index = edit.overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        edit.overlays[index] = overlay
        update(edit)
    }

    private func replace(_ overlay: MediaOverlay) {
        liveOverlay = overlay
    }

    /// Measured on the stage: the overlay moves under the pointer, so its
    /// own space would move with it and the drag would feed on itself.
    private func move(_ overlay: MediaOverlay, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(MediaStage.space))
            .onChanged { value in
                let start = beginOverlay(currentOverlay(overlay.id) ?? overlay)
                var moved = currentOverlay(overlay.id) ?? overlay
                moved.center = CGPoint(
                    x: min(max(start.center.x + value.translation.width / size.width, 0), 1),
                    y: min(max(start.center.y + value.translation.height / size.height, 0), 1)
                )
                replace(moved)
            }
            .onEnded { _ in endOverlay() }
    }

    /// A pinch on the trackpad sizes it.
    private func pinch(_ overlay: MediaOverlay) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = beginOverlay(currentOverlay(overlay.id) ?? overlay)
                var sized = currentOverlay(overlay.id) ?? overlay
                sized.size = min(max(start.size * value.magnification, MediaOverlay.sizes.lowerBound), MediaOverlay.sizes.upperBound)
                replace(sized)
            }
            .onEnded { _ in endOverlay() }
    }

    /// Two fingers turning on the trackpad turn it.
    private func turn(_ overlay: MediaOverlay) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                let start = beginOverlay(currentOverlay(overlay.id) ?? overlay)
                var turned = currentOverlay(overlay.id) ?? overlay
                turned.rotation = start.rotation + value.rotation.radians
                replace(turned)
            }
            .onEnded { _ in endOverlay() }
    }

    private func currentOverlay(_ id: MediaOverlay.ID) -> MediaOverlay? {
        if let liveOverlay, liveOverlay.id == id { return liveOverlay }
        return edit.overlays.first { $0.id == id }
    }
}

/// A rectangle at a place of its own inside the shape's frame.
private nonisolated struct LocalRect: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        Path(rect)
    }
}

/// The corner knob of a picked overlay: drag it out to enlarge, round to
/// turn, for a mouse without a trackpad's pinch and twist.
private struct OverlayHandle: View {
    let overlay: MediaOverlay
    let layout: StageLayout
    let begin: (MediaOverlay) -> Void
    let change: (MediaOverlay) -> Void
    let end: () -> Void

    @State private var start: (overlay: MediaOverlay, distance: CGFloat, angle: CGFloat)?

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 20, height: 20)
            .background(.white, in: .circle)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .contentShape(.circle.inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(MediaStage.space))
                    .onChanged { value in
                        let center = CGPoint(
                            x: layout.canvas.minX + overlay.center.x * layout.canvas.width,
                            y: layout.canvas.minY + overlay.center.y * layout.canvas.height
                        )
                        let vector = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
                        let distance = max(hypot(vector.x, vector.y), 1)
                        let angle = atan2(vector.y, vector.x)
                        let start = self.start ?? (overlay, distance, angle)
                        if self.start == nil {
                            begin(overlay)
                            self.start = start
                        }
                        var changed = overlay
                        changed.size = min(
                            max(start.overlay.size * Double(distance / start.distance), MediaOverlay.sizes.lowerBound),
                            MediaOverlay.sizes.upperBound
                        )
                        changed.rotation = start.overlay.rotation + Double(angle - start.angle)
                        change(changed)
                    }
                    .onEnded { _ in
                        start = nil
                        end()
                    }
            )
            .help("Drag to resize and rotate")
    }
}

// MARK: Crop

/// The crop's frame while cropping: the rest dimmed, corner and edge
/// handles, a rule-of-thirds grid while it moves, and a drag inside moves
/// it.
private struct CropFrame: View {
    let layout: StageLayout
    /// Width over height in pixels, when locked.
    let aspect: CGFloat?
    let picture: CGSize
    let current: CGRect
    let begin: () -> Void
    let change: (CGRect) -> Void

    @State private var from: CGRect?

    var body: some View {
        let crop = layout.crop
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(layout.canvas)
                path.addRect(crop)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for third in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(third) / 3
                    let y = crop.minY + crop.height * CGFloat(third) / 3
                    path.move(to: CGPoint(x: x, y: crop.minY))
                    path.addLine(to: CGPoint(x: x, y: crop.maxY))
                    path.move(to: CGPoint(x: crop.minX, y: y))
                    path.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(.white.opacity(from != nil ? 0.5 : 0), lineWidth: 0.75)
            .animation(.easeOut(duration: 0.15), value: from != nil)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white, lineWidth: 1)
                .frame(width: crop.width, height: crop.height)
                .contentShape(.rect)
                .gesture(handleDrag(dx: 0, dy: 0))
                .offset(x: crop.minX, y: crop.minY)
                .pointerStyle(.grabIdle)

            ForEach(Self.handles, id: \.self) { handle in
                if aspect == nil || (handle.dx != 0 && handle.dy != 0) {
                    CropHandleShape(dx: handle.dx, dy: handle.dy)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect.inset(by: -8))
                        .gesture(handleDrag(dx: handle.dx, dy: handle.dy))
                        .position(
                            x: crop.midX + CGFloat(handle.dx) * crop.width / 2 - CGFloat(handle.dx) * 9,
                            y: crop.midY + CGFloat(handle.dy) * crop.height / 2 - CGFloat(handle.dy) * 9
                        )
                }
            }
        }
    }

    private struct Handle: Hashable {
        let dx: Int
        let dy: Int
    }

    private static let handles: [Handle] = [
        Handle(dx: -1, dy: -1), Handle(dx: 1, dy: -1), Handle(dx: -1, dy: 1), Handle(dx: 1, dy: 1),
        Handle(dx: 0, dy: -1), Handle(dx: 0, dy: 1), Handle(dx: -1, dy: 0), Handle(dx: 1, dy: 0),
    ]

    private func handleDrag(dx: Int, dy: Int) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(MediaStage.space))
            .onChanged { value in
                let base = from ?? current
                if from == nil {
                    from = current
                    begin()
                }
                let delta = CGSize(
                    width: value.translation.width / max(layout.canvas.width, 1),
                    height: value.translation.height / max(layout.canvas.height, 1)
                )
                change(Self.resize(base, dx: dx, dy: dy, by: delta, aspect: fractional))
            }
            .onEnded { _ in from = nil }
    }

    /// The locked aspect in canvas fractions.
    private var fractional: CGFloat? {
        aspect.map { $0 * picture.height / max(picture.width, 1) }
    }

    /// `rect` with the handle at (`dx`, `dy`) moved by `delta`; (0, 0)
    /// moves the whole crop. An aspect keeps its shape from the fixed
    /// corner.
    static func resize(_ rect: CGRect, dx: Int, dy: Int, by delta: CGSize, aspect: CGFloat?) -> CGRect {
        if dx == 0, dy == 0 {
            let x = min(max(rect.minX + delta.width, 0), 1 - rect.width)
            let y = min(max(rect.minY + delta.height, 0), 1 - rect.height)
            return CGRect(x: x, y: y, width: rect.width, height: rect.height)
        }
        let minimum = MediaEdit.minCrop
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if dx < 0 { minX = min(max(rect.minX + delta.width, 0), maxX - minimum) }
        if dx > 0 { maxX = max(min(rect.maxX + delta.width, 1), minX + minimum) }
        if dy < 0 { minY = min(max(rect.minY + delta.height, 0), maxY - minimum) }
        if dy > 0 { maxY = max(min(rect.maxY + delta.height, 1), minY + minimum) }
        guard let aspect, dx != 0, dy != 0 else {
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        // Grow to the larger of the two, then shrink to the room left
        // beside the fixed corner.
        var width = maxX - minX, height = maxY - minY
        if width / height > aspect { height = width / aspect } else { width = height * aspect }
        let roomX = dx < 0 ? rect.maxX : 1 - rect.minX
        let roomY = dy < 0 ? rect.maxY : 1 - rect.minY
        let fit = min(1, roomX / width, roomY / height)
        width *= fit
        height *= fit
        let x = dx < 0 ? rect.maxX - width : rect.minX
        let y = dy < 0 ? rect.maxY - height : rect.minY
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// An L at a corner, or a bar on an edge.
private nonisolated struct CropHandleShape: Shape {
    let dx: Int
    let dy: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x: CGFloat = dx < 0 ? rect.minX : (dx > 0 ? rect.maxX : rect.midX)
        let y: CGFloat = dy < 0 ? rect.minY : (dy > 0 ? rect.maxY : rect.midY)
        if dx != 0, dy != 0 {
            path.move(to: CGPoint(x: x, y: rect.midY))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: rect.midX, y: y))
        } else if dx != 0 {
            path.move(to: CGPoint(x: x, y: rect.minY + 3))
            path.addLine(to: CGPoint(x: x, y: rect.maxY - 3))
        } else {
            path.move(to: CGPoint(x: rect.minX + 3, y: y))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: y))
        }
        return path
    }
}

// MARK: Straighten

/// A ruler under the picture while cropping: drag it to straighten, up to
/// 45 degrees either way. A click at zero resets it; crossing zero taps.
struct StraightenDial: View {
    /// Degrees, clockwise positive, as it looks.
    let value: Double
    let begin: () -> Void
    let change: (Double) -> Void

    @State private var start: Double?
    private let perDegree: CGFloat = 7

    var body: some View {
        VStack(spacing: 4) {
            Text(value == 0 ? "0°" : String(format: "%+.0f°", value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(value == 0 ? .white.opacity(0.7) : .white)
                .contentTransition(.numericText())
            Canvas { context, size in
                let center = size.width / 2
                for degree in -45...45 {
                    let x = center + (CGFloat(degree) - CGFloat(value)) * perDegree
                    guard x > -2, x < size.width + 2 else { continue }
                    let major = degree % 10 == 0
                    let height: CGFloat = major ? 12 : 6
                    let distance = abs(x - center) / center
                    context.fill(
                        Path(CGRect(x: x - 0.5, y: (size.height - height) / 2, width: 1, height: height)),
                        with: .color(.white.opacity((major ? 0.9 : 0.5) * (1 - distance * 0.7)))
                    )
                }
                context.fill(
                    Path(roundedRect: CGRect(x: center - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                    with: .color(.yellow)
                )
            }
            .frame(width: 300, height: 22)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                .init(color: .black, location: 0.8), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    if start == nil {
                        start = value
                        begin()
                    }
                    let proposed = (start ?? 0) - Double(drag.translation.width / perDegree)
                    // Snap to level near zero, with a tap to feel it.
                    let snapped = abs(proposed) < 0.6 ? 0 : (proposed * 10).rounded() / 10
                    let clamped = min(max(snapped, -MediaEdit.maxStraighten), MediaEdit.maxStraighten)
                    if clamped == 0, value != 0 {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    change(clamped)
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) {
            begin()
            change(0)
        }
        .help("Drag to straighten; double-click to level")
        .accessibilityElement()
        .accessibilityLabel("Straighten")
        .accessibilityValue(Text("\(Int(value)) degrees"))
        .accessibilityAdjustableAction { direction in
            begin()
            change(min(max(value + (direction == .increment ? 1 : -1), -MediaEdit.maxStraighten), MediaEdit.maxStraighten))
        }
    }
}

// MARK: Video

/// A player's picture without controls; the editor draws its own.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resize
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
