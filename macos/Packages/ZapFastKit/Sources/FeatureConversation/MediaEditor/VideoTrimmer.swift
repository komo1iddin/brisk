import SwiftUI
import ZapFastCore
import ZapFastDesign

/// Under a video: play and pause, and a strip of its frames with a handle
/// at each end to keep only part of it. Dragging a handle shows that
/// frame; the length kept is shown beside it.
struct VideoTrimmer: View {
    let video: EditorVideo
    let trim: ClosedRange<Double>?
    let begin: () -> Void
    let change: (ClosedRange<Double>?) -> Void

    @State private var dragging: End?
    @State private var dragStart: ClosedRange<Double>?
    @State private var hovered = false

    private enum End { case lower, upper }

    private let height: CGFloat = 44
    private let handle: CGFloat = 12

    var body: some View {
        HStack(spacing: Metrics.m) {
            Button {
                video.togglePlay()
            } label: {
                Image(systemName: video.playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .editorButton(diameter: 40)
            .help(video.playing ? "Pause" : "Play")

            GeometryReader { proxy in
                strip(width: proxy.size.width)
            }
            .frame(height: height)

            Text(Self.format(range.upperBound - range.lowerBound))
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 44, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .onChange(of: trim) { video.range = range }
        .onAppear { video.range = range }
    }

    private var duration: Double { max(video.info.duration, 0.1) }
    private var range: ClosedRange<Double> { trim ?? 0...duration }
    /// The shortest part that can be kept.
    private var shortest: Double { min(1, duration) }

    private func strip(width: CGFloat) -> some View {
        let inner = max(width - handle * 2, 1)
        let lowerX = handle + inner * range.lowerBound / duration
        let upperX = handle + inner * range.upperBound / duration
        let playX = handle + inner * min(max(video.time, 0), duration) / duration
        return ZStack(alignment: .topLeading) {
            // The frames, dimmed outside what is kept.
            HStack(spacing: 0) {
                ForEach(Array(video.frames.enumerated()), id: \.offset) { _, frame in
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: inner / CGFloat(max(video.frames.count, 1)), height: height - 6)
                        .clipped()
                }
            }
            .frame(width: inner, height: height - 6, alignment: .leading)
            .background(.white.opacity(0.08))
            .clipShape(.rect(cornerRadius: 4))
            .offset(x: handle, y: 3)

            Path { path in
                path.addRect(CGRect(x: handle, y: 3, width: lowerX - handle, height: height - 6))
                path.addRect(CGRect(x: upperX, y: 3, width: width - handle - upperX, height: height - 6))
            }
            .fill(.black.opacity(0.6))

            // The kept part's frame, with a grip at each end.
            TrimFrame(handle: handle)
                .fill(.white, style: FillStyle(eoFill: true))
                .frame(width: upperX - lowerX + handle * 2, height: height)
                .offset(x: lowerX - handle)
                .shadow(color: .black.opacity(0.3), radius: 2)
                .allowsHitTesting(false)

            if video.playing || dragging == nil {
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: height + 6)
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .offset(x: playX - 1.5, y: -3)
                    .opacity(video.time > range.lowerBound + 0.01 || video.playing ? 1 : 0)
                    .allowsHitTesting(false)
            }

            grip(.lower, x: lowerX - handle, inner: inner)
            grip(.upper, x: upperX, inner: inner)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(.rect)
        .onTapGesture { location in
            // A click in the kept part moves the playhead there.
            let seconds = Double((location.x - handle) / inner) * duration
            if range.contains(seconds) { video.seek(seconds) }
        }
    }

    private func grip(_ end: End, x: CGFloat, inner: CGFloat) -> some View {
        Color.clear
            .frame(width: handle + 10, height: height)
            .contentShape(.rect)
            .offset(x: x - 5)
            .pointerStyle(.frameResize(position: end == .lower ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? range
                        if dragStart == nil {
                            dragStart = start
                            dragging = end
                            begin()
                            video.player.pause()
                        }
                        let delta = Double(value.translation.width / inner) * duration
                        var lower = start.lowerBound, upper = start.upperBound
                        switch end {
                        case .lower: lower = min(max(0, start.lowerBound + delta), upper - shortest)
                        case .upper: upper = max(min(duration, start.upperBound + delta), lower + shortest)
                        }
                        let kept = lower...upper
                        change(kept.lowerBound <= 0.01 && kept.upperBound >= duration - 0.01 ? nil : kept)
                        video.seek(end == .lower ? lower : upper)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        dragging = nil
                        video.seek(range.lowerBound)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(end == .lower ? "Start" : "End")
            .accessibilityValue(Text(Self.format(end == .lower ? range.lowerBound : range.upperBound)))
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A rounded frame whose sides are grips: the outline minus the inside.
private nonisolated struct TrimFrame: Shape {
    let handle: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 6, style: .continuous)
        path.addRect(rect.insetBy(dx: handle, dy: 3))
        // Two small grips on the sides.
        for x in [rect.minX + handle / 2, rect.maxX - handle / 2] {
            path.addRoundedRect(
                in: CGRect(x: x - 1, y: rect.midY - 7, width: 2, height: 14), cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}

/// A document among the photos: its Finder icon, name and size.
struct DocumentCard: View {
    let attachment: Attachment

    var body: some View {
        VStack(spacing: Metrics.m) {
            if let url = attachment.fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 128, height: 128)
                Text(url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    Text(Int64(size), format: .byteCount(style: .file))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(Metrics.xl)
        .frame(maxWidth: 360)
    }
}
