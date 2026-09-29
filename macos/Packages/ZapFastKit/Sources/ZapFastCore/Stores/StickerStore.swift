import Foundation
import Observation
import ZapFastBridge

/// The sticker and GIF picker's contents.
@Observable
public final class StickerStore {
    /// Favorites, packs, recent and received stickers, once loaded.
    public private(set) var library: StickerLibrary?

    public private(set) var gifs: [GifInfo] = []
    public private(set) var gifError: GifFailure?
    /// A GIF search is on its way.
    public internal(set) var gifPending = false

    public init() {}

    public func isFavorite(_ path: String) -> Bool {
        library?.favorites.contains(path) ?? false
    }

    /// Stickers matching `query` through upstream's search.
    public func search(_ query: String) -> [String] {
        guard let library else { return [] }
        return searchStickers(library: library, query: query)
    }

    // MARK: Applying events

    func apply(_ library: StickerLibrary) {
        self.library = library
    }

    func applyGifs(query: String, gifs: [GifInfo], error: GifFailure?, wanted: String) {
        guard query == wanted else { return }
        gifPending = false
        self.gifs = gifs
        gifError = error
    }

    func clear() {
        library = nil
        gifs = []
        gifError = nil
        gifPending = false
    }
}
