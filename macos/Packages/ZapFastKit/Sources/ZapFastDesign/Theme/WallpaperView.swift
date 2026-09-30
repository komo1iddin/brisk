import AppKit
import SwiftUI

/// Draws a chat's wallpaper to fill its space.
public struct WallpaperView: View {
    private let fill: WallpaperFill
    @Environment(\.colorScheme) private var scheme

    public init(_ fill: WallpaperFill) {
        self.fill = fill
    }

    public var body: some View {
        switch fill {
        case .none:
            Color.clear
        case let .color(color, ink):
            ZStack {
                color
                if let ink, let tile = Doodles.tile {
                    Image(nsImage: tile)
                        .renderingMode(.template)
                        .resizable(resizingMode: .tile)
                        .foregroundStyle(ink)
                        .accessibilityHidden(true)
                }
            }
        case .gradient(let colors):
            MeshGradient(
                width: 2, height: 2,
                points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                colors: colors.count == 4 ? colors : [.gray, .gray, .gray, .gray]
            )
        case let .photo(url, dim):
            PhotoWallpaper(url: url)
                .overlay(Color.black.opacity(scheme == .dark ? dim : 0))
        }
    }
}

private struct PhotoWallpaper: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .task(id: url) { image = await Thumbnails.load(url, points: 1600) }
        .accessibilityHidden(true)
    }
}

/// Upstream's doodle tile (Lucide icons, ISC), bundled with the app from
/// `assets/wallpaper.svg`; drawn as a template in the theme's ink.
public enum Doodles {
    public static let tile: NSImage? = {
        guard let url = Bundle.main.url(forResource: "wallpaper", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()
}
