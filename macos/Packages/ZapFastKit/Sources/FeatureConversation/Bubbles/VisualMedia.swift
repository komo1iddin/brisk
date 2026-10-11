/// A photo, video or sticker inside a bubble, and the badge that shows a
/// download's progress over it.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Photos, videos, and stickers: the preview at the picture's shape, a
/// download button until the file is here, then a click opens it. A video
/// plays inside its message; a GIF and an animated sticker move while the
/// pointer is over them in the active window, as upstream's do.
struct VisualMedia: View {
    let message: MessageRecord
    let media: MediaInfo
    let symbol: String
    let model: AppModel
    var seconds: UInt32?
    var sticker = false

    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = displaySize
        Group {
            if playsInline {
                PlayerView(player: model.video.player, fill: isNote, minimal: isNote)
            } else {
                poster(size)
                    .contentShape(shape)
                    .onTapGesture(perform: activate)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityTitle)
                    .accessibilityValue(accessibilityState)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .onHover { hovering = $0 }
        .draggableAttachment(message)
        .task(id: Thumbnails.scope([model.accountID, message.chat, message.id, media.path ?? "", Thumbnails.contentID(message.thumbnail)])) { await load(size) }
        .onDisappear {
            if case .video = message.content { model.videoHidden(message) }
        }
    }

    private func poster(_ size: CGSize) -> some View {
        ZStack {
            if let url = message.mediaURL, isAnimatedSticker {
                AnimatedImage(url: url, still: image, points: max(size.width, size.height), playing: moves)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                if media.path != nil || sticker {
                    Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            if isGif, moves, let url = message.mediaURL {
                LoopingVideo(url: url)
            }
            overlay
        }
    }

    @ViewBuilder private var overlay: some View {
        let state = model.conversations.download(MessageKey(chat: message.chat, message: message.id))
        if media.path == nil, !sticker {
            DownloadBadge(state: state, size: media.size)
        } else if isGif {
            if !moves {
                Text("GIF")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(.white)
            }
        } else if case .video = message.content {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white, .black.opacity(0.35))
        }
        if let seconds, seconds > 0, !isGif {
            Text(Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond)))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: isNote ? nil : .infinity, alignment: isNote ? .center : .bottomLeading)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(Metrics.s)
        }
    }

    private var key: MessageKey { MessageKey(chat: message.chat, message: message.id) }

    /// "Video, 0:42", "GIF", "Photo", "Sticker", read as one element.
    private var accessibilityTitle: Text {
        if sticker { return Text("Sticker") }
        if isGif { return Text("GIF") }
        if case .video = message.content {
            let length = seconds.map { Duration.seconds(Int($0)).formatted(.time(pattern: .minuteSecond)) }
            if let length { return isNote ? Text("Video message, \(length)") : Text("Video, \(length)") }
            return isNote ? Text("Video message") : Text("Video")
        }
        return Text("Photo")
    }

    private var accessibilityState: Text {
        guard media.path == nil, !sticker else { return Text(verbatim: "") }
        switch model.conversations.download(key) {
        case .downloading: return Text("Downloading")
        case .failed: return Text("Download failed")
        case nil: return Text("Not downloaded")
        }
    }

    /// This message's video is the one playing (or paused) in place.
    private var playsInline: Bool {
        guard case .video = message.content, !isGif else { return false }
        return model.video.isCurrent(key)
    }

    private var isGif: Bool {
        if case .video(_, _, _, true, _) = message.content { true } else { false }
    }

    /// A round video message.
    private var isNote: Bool {
        if case .video(_, _, _, _, true) = message.content { true } else { false }
    }

    private var isAnimatedSticker: Bool {
        if case .sticker(_, true) = message.content { true } else { false }
    }

    /// Animations play under the pointer while the window is in front,
    /// and not at all with Reduce Motion on.
    private var moves: Bool {
        hovering && activeState != .inactive && media.path != nil && !reduceMotion
    }

    private var shape: AnyShape {
        if isNote { return AnyShape(Circle()) }
        return AnyShape(RoundedRectangle(cornerRadius: sticker ? 0 : Metrics.bubbleRadius - Metrics.xs, style: .continuous))
    }

    private var displaySize: CGSize {
        if isNote { return CGSize(width: 220, height: 220) }
        let bound: CGFloat = sticker ? 160 : 300
        guard let width = media.width, let height = media.height, width > 0, height > 0 else {
            return CGSize(width: bound, height: sticker ? bound : bound * 0.66)
        }
        let scale = min(bound / CGFloat(width), bound / CGFloat(height), 1.5)
        return CGSize(width: max(120, CGFloat(width) * scale), height: max(80, CGFloat(height) * scale))
    }

    private func load(_ size: CGSize) async {
        let points = max(size.width, size.height)
        let loaded: NSImage?
        if let path = media.path, media.mime.hasPrefix("image") {
            loaded = await Thumbnails.load(URL(filePath: path), points: points)
        } else if let thumbnail = message.thumbnail {
            loaded = await Thumbnails.load(thumbnail, key: Thumbnails.scope([model.accountID, message.chat, "thumb", message.id]), points: points)
        } else {
            loaded = nil
        }
        guard !Task.isCancelled else { return }
        image = loaded
        model.autoDownload(message)
    }

    /// A round video message plays in place (downloading first); photos,
    /// videos and GIFs open in the media viewer; a sticker in Quick Look.
    private func activate() {
        if isNote {
            model.playVideo(message)
        } else if MediaGallery.kind(of: message) != nil {
            // Photos, videos and GIFs open in the media viewer, which
            // downloads what is not here yet.
            model.openMediaViewer(message)
        } else if let url = message.mediaURL {
            QuickLook.shared.show([url])
        } else {
            model.download(message)
        }
    }
}

struct DownloadBadge: View {
    let state: DownloadState?
    let size: UInt64

    var body: some View {
        Group {
            switch state {
            case .downloading:
                ProgressView().controlSize(.small).tint(.white)
            case .failed:
                Label("Retry", systemImage: "arrow.clockwise")
            case nil:
                Label(
                    size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : String(localized: "Download"),
                    systemImage: "arrow.down.circle.fill"
                )
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, Metrics.s).padding(.vertical, Metrics.xs)
        .background(.black.opacity(0.5), in: Capsule())
        .foregroundStyle(.white)
    }
}
