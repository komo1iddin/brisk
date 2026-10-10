/// Stickers and GIFs: the picker's packs, its favourites, and GIF search.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: stickers and GIFs

    /// The picker opened: load its stickers, as upstream does each time.
    public func loadStickers() {
        backend.send(.recentStickers)
    }

    /// Sends a sticker, replying if a reply is set.
    public func sendSticker(_ path: String, in chat: String) {
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendSticker(chat: chat, path: path, quoting: quoting))
        followSentChat()
    }

    /// Fetches a pack shared in a chat and shows it.
    public func viewStickerPack(_ message: MessageRecord) {
        guard case .stickerPack = message.content else { return }
        stickerPackPreview = StickerPackPreview(chat: message.chat, state: .loading)
        backend.send(.viewStickerPack(chat: message.chat, message: message.id))
    }

    /// Keeps the viewed pack in the picker's packs.
    public func addViewedStickerPack() {
        guard case .ready(let pack, _) = stickerPackPreview?.state else { return }
        stickerPackPreview = nil
        backend.send(.addStickerPack(dir: pack.dir, name: pack.name))
    }

    /// Starts an empty pack of our own.
    public func createStickerPack(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        backend.send(.createStickerPack(name: name))
    }

    /// Files a sticker into one of our own packs, or takes it out.
    public func setSticker(_ path: String, in pack: StickerPackInfo, member: Bool) {
        guard pack.local else { return }
        backend.send(.setStickerPack(pack: pack.dir, sticker: path, member: member))
    }

    public func deleteStickerPack(_ pack: StickerPackInfo) {
        backend.send(.deleteStickerPack(dir: pack.dir))
    }

    /// Imports a pack from a signal.art link, which the worker fetches
    /// from Signal's servers; a bad link ends with its error.
    public func importStickerPack(from link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        backend.send(.importStickerUrl(url: link))
    }

    /// Adds a pack from a `.wastickers` archive (WhatsApp's sticker apps
    /// share them) chosen in the open panel upstream shows for it.
    public func importStickerArchive() {
        backend.send(.pickStickerArchive)
    }

    /// Makes a sticker from `picture`: sent to `chat`, or without one added
    /// to Favorites. Upstream crops, scales to 512 and encodes WebP.
    public func makeSticker(
        from picture: StickerPicture,
        crop: StickerCropInfo,
        keepTransparency: Bool,
        emojis: [String],
        sendTo chat: String?
    ) {
        backend.send(.makeSticker(
            source: picture.url.path(percentEncoded: false), crop: crop,
            transparent: picture.transparent && keepTransparency, emojis: emojis, chat: chat
        ))
    }

    /// Sends one of our packs to a chat as a sticker pack message.
    public func sendStickerPack(_ pack: StickerPackInfo, in chat: String) {
        guard session.isConnected else { return }
        backend.send(.sendStickerPack(chat: chat, dir: pack.dir))
        followSentChat()
    }

    public func toggleFavoriteSticker(_ path: String) {
        backend.send(stickers.isFavorite(path) ? .forgetSticker(path: path) : .saveSticker(path: path))
    }

    public func removeRecentSticker(_ path: String) {
        backend.send(.removeRecentSticker(path: path))
    }

    /// Whether GIF search has a key: ours, or one built into upstream.
    public var canSearchGifs: Bool {
        giphyKey(own: preferences.giphyKey) != nil
    }

    /// Searches GIPHY once typing pauses; an empty query lists trending.
    public func searchGifs(_ text: String) {
        gifSearchTask?.cancel()
        guard let key = giphyKey(own: preferences.giphyKey) else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        wantedGifQuery = query
        stickers.gifPending = true
        gifSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.backend.send(.searchGifs(query: query, key: key))
        }
    }

    public func sendGif(_ gif: GifInfo, in chat: String) {
        let quoting = replyingTo.removeValue(forKey: chat)?.id
        backend.send(.sendGif(chat: chat, gif: gif, quoting: quoting))
        followSentChat()
    }
}
