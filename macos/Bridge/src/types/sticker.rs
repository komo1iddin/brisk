use std::collections::HashMap;
use std::path::PathBuf;

use zapfast::model::{Gif, GifError, StickerPack};

use super::path_string;

/// A sticker pack on this computer.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StickerPackInfo {
    pub name: String,
    pub dir: String,
    /// WebP files.
    pub stickers: Vec<String>,
    /// Put together in ZapFast.
    pub local: bool,
}

impl From<StickerPack> for StickerPackInfo {
    fn from(pack: StickerPack) -> Self {
        let StickerPack {
            name,
            dir,
            stickers,
            local,
        } = pack;
        Self {
            name,
            dir: path_string(dir),
            stickers: stickers.into_iter().map(path_string).collect(),
            local,
        }
    }
}

impl From<StickerPackInfo> for StickerPack {
    fn from(pack: StickerPackInfo) -> Self {
        let StickerPackInfo {
            name,
            dir,
            stickers,
            local,
        } = pack;
        Self {
            name,
            dir: dir.into(),
            stickers: stickers.into_iter().map(PathBuf::from).collect(),
            local,
        }
    }
}

/// The emojis one sticker is tagged with.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StickerEmojis {
    pub path: String,
    pub emojis: Vec<String>,
}

/// Everything the picker shows, as the `Stickers` event carries it; also
/// handed back to `search_stickers`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StickerLibrary {
    pub favorites: Vec<String>,
    pub packs: Vec<StickerPackInfo>,
    pub recent: Vec<String>,
    /// Stickers other people sent.
    pub received: Vec<String>,
    pub emojis: Vec<StickerEmojis>,
}

impl StickerLibrary {
    pub(crate) fn new(
        favorites: Vec<PathBuf>,
        packs: Vec<StickerPack>,
        recent: Vec<PathBuf>,
        received: Vec<PathBuf>,
        emojis: HashMap<PathBuf, Vec<String>>,
    ) -> Self {
        let mut emojis: Vec<StickerEmojis> = emojis
            .into_iter()
            .map(|(path, emojis)| StickerEmojis {
                path: path_string(path),
                emojis,
            })
            .collect();
        emojis.sort_by(|a, b| a.path.cmp(&b.path));
        Self {
            favorites: favorites.into_iter().map(path_string).collect(),
            packs: packs.into_iter().map(Into::into).collect(),
            recent: recent.into_iter().map(path_string).collect(),
            received: received.into_iter().map(path_string).collect(),
            emojis,
        }
    }
}

/// A GIF found through GIPHY.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GifInfo {
    pub id: String,
    /// Downloaded still frame.
    pub still: Option<String>,
    pub mp4: String,
    pub width: u32,
    pub height: u32,
}

impl From<Gif> for GifInfo {
    fn from(gif: Gif) -> Self {
        let Gif {
            id,
            still,
            mp4,
            width,
            height,
        } = gif;
        Self {
            id,
            still: still.map(path_string),
            mp4,
            width,
            height,
        }
    }
}

impl From<GifInfo> for Gif {
    fn from(gif: GifInfo) -> Self {
        let GifInfo {
            id,
            still,
            mp4,
            width,
            height,
        } = gif;
        Self {
            id,
            still: still.map(PathBuf::from),
            mp4,
            width,
            height,
        }
    }
}

/// Why a GIF search failed.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GifFailure {
    pub message: String,
    /// GIPHY rejected the key.
    pub bad_key: bool,
}

impl From<GifError> for GifFailure {
    fn from(error: GifError) -> Self {
        let GifError { message, bad_key } = error;
        Self { message, bad_key }
    }
}
