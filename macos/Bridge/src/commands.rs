//! Commands Swift may send, and their upstream equivalents.
//!
//! This is a deliberate subset: a command is added when a screen needs it.
//! Upstream's internal result commands (`Sent`, `Downloaded`, …) are never
//! exposed. File pickers are native on the Swift side, so the `Pick*`
//! commands are replaced by their path-carrying counterparts.

use std::path::PathBuf;

use zapfast::backend::Command;

use crate::types::{GifInfo, PageKey, PollDraftInfo};

#[derive(Debug, Clone, uniffi::Enum)]
pub enum BridgeCommand {
    // Link
    /// Pair by phone number instead of QR; the phone shows a code prompt.
    PairWithPhone {
        phone: String,
    },
    Reconnect,
    /// Unlink this device here and on the phone.
    Unlink,
    /// Set aside an unreadable archive and start over with a new link.
    StartOverArchive,
    /// Whether the person is looking at the app.
    SetOnline {
        online: bool,
    },
    /// Empty follows the system.
    SetProxy {
        proxy: String,
    },

    // Reading
    /// Archived messages before `before`, or the newest page.
    LoadChat {
        chat: String,
        before: Option<PageKey>,
    },
    /// Archived messages from `message` up to the page that starts at
    /// `before`, to reach a search hit or a quote above what is loaded.
    LoadUntil {
        chat: String,
        message: String,
        before: PageKey,
    },
    /// Ask the phone for messages older than the archive has.
    FetchOlder {
        chat: String,
    },
    MarkRead {
        chat: String,
        receipts: bool,
    },
    MarkUnread {
        chat: String,
    },
    Download {
        chat: String,
        message: String,
        card: Option<u32>,
    },
    /// A voice message was played: the blue microphone for its sender.
    MarkPlayed {
        chat: String,
        message: String,
        sender: String,
        receipts: bool,
    },
    FetchAvatar {
        id: String,
        full: bool,
    },
    SearchMessages {
        query: String,
    },
    SearchChatMessages {
        chat: String,
        query: String,
        from: Option<i64>,
        until: Option<i64>,
    },

    // Writing
    SendText {
        chat: String,
        text: String,
        quoting: Option<String>,
        mentions: Vec<String>,
    },
    SendFiles {
        chat: String,
        paths: Vec<String>,
        caption: Option<String>,
        mentions: Vec<String>,
        quoting: Option<String>,
    },
    /// A recorded voice message: mono samples at `voice_sample_rate()`.
    /// The worker encodes it and draws its waveform.
    SendVoice {
        chat: String,
        samples: Vec<f32>,
        quoting: Option<String>,
    },
    EditText {
        chat: String,
        id: String,
        text: String,
        mentions: Vec<String>,
    },
    /// Sends a new poll; answered by `PollCreated`.
    CreatePoll {
        chat: String,
        draft: PollDraftInfo,
    },
    /// Our whole choice in a poll; empty withdraws the vote.
    VotePoll {
        chat: String,
        message: String,
        choices: Vec<u32>,
    },
    /// Ask the phone for a poll's earlier votes.
    RefreshPoll {
        chat: String,
        message: String,
    },
    React {
        chat: String,
        message: String,
        emoji: String,
    },
    /// Delete for everyone.
    Revoke {
        chat: String,
        id: String,
    },
    /// Delete for me.
    DeleteLocal {
        chat: String,
        id: String,
    },
    Forward {
        from_chat: String,
        messages: Vec<String>,
        to_chat: String,
    },
    Composing {
        chat: String,
        composing: bool,
    },
    SaveDraft {
        chat: String,
        text: String,
    },

    // Chat management
    SetArchived {
        chat: String,
        archived: bool,
    },
    SetPinned {
        chat: String,
        pinned: bool,
    },
    SetFavorite {
        chat: String,
        favorite: bool,
    },
    /// Mute end in Unix seconds, `Some(0)` indefinitely, `None` unmutes.
    SetMuted {
        chat: String,
        until: Option<i64>,
    },
    ClearChat {
        chat: String,
    },
    DeleteChat {
        chat: String,
    },
    /// Create an archive chat before its first message.
    EnsureChat {
        chat: String,
        name: String,
    },

    // Stickers and GIFs
    /// Loads the picker's stickers; answered by `Stickers`.
    RecentStickers,
    /// Sends a WebP sticker.
    SendSticker {
        chat: String,
        path: String,
        quoting: Option<String>,
    },
    /// Adds a sticker to Favorites.
    SaveSticker {
        path: String,
    },
    /// Takes a sticker out of Favorites.
    ForgetSticker {
        path: String,
    },
    /// Takes a sticker out of Recent here and on the phone.
    RemoveRecentSticker {
        path: String,
    },
    /// Searches GIPHY, or lists trending GIFs for an empty query.
    SearchGifs {
        query: String,
        key: String,
    },
    /// Sends a GIF as a short looping video.
    SendGif {
        chat: String,
        gif: GifInfo,
        quoting: Option<String>,
    },

    // Our profile
    /// Changes our name and About; `None` keeps the current one.
    SetProfile {
        name: Option<String>,
        about: Option<String>,
    },
    /// Makes a square JPEG our profile picture.
    SetProfilePicture {
        jpeg: Vec<u8>,
    },

    // Groups and contacts
    /// Renames a group for everyone in it.
    SetGroupName {
        chat: String,
        name: String,
    },
    /// Sets a group's photo to a square JPEG, or removes it with `None`.
    SetGroupPicture {
        chat: String,
        jpeg: Option<Vec<u8>>,
    },
    /// Leaves a group or channel; `archive` also files it under Archived.
    LeaveGroup {
        chat: String,
        archive: bool,
    },
    /// Checks that a number is on WhatsApp, optionally saves a name for
    /// it, and answers with `ContactReady` so its chat can open.
    NewContact {
        phone: String,
        full_name: Option<String>,
        first_name: Option<String>,
        to_phone: bool,
    },
    /// Saves a name through contact sync; `to_phone` also adds it to the
    /// phone's address book.
    SaveContact {
        id: String,
        full_name: String,
        first_name: Option<String>,
        to_phone: bool,
    },
}

impl BridgeCommand {
    pub(crate) fn into_upstream(self) -> Command {
        match self {
            Self::PairWithPhone { phone } => Command::PairWithPhone(phone),
            Self::Reconnect => Command::Reconnect,
            Self::Unlink => Command::Unlink,
            Self::StartOverArchive => Command::StartOverArchive,
            Self::SetOnline { online } => Command::SetOnline(online),
            Self::SetProxy { proxy } => Command::SetProxy(proxy),

            Self::LoadChat { chat, before } => Command::LoadChat {
                chat,
                before: before.map(Into::into),
            },
            Self::LoadUntil {
                chat,
                message,
                before,
            } => Command::LoadUntil {
                chat,
                id: message,
                before: before.into(),
            },
            Self::FetchOlder { chat } => Command::FetchOlder(chat),
            Self::MarkRead { chat, receipts } => Command::MarkRead { chat, receipts },
            Self::MarkUnread { chat } => Command::MarkUnread(chat),
            Self::Download {
                chat,
                message,
                card,
            } => Command::Download {
                card: card.map(|card| card as usize),
                chat,
                message,
            },
            Self::MarkPlayed {
                chat,
                message,
                sender,
                receipts,
            } => Command::MarkPlayed {
                chat,
                message,
                sender,
                receipts,
            },
            Self::FetchAvatar { id, full } => Command::FetchAvatar { id, full },
            Self::SearchMessages { query } => Command::SearchMessages { query },
            Self::SearchChatMessages {
                chat,
                query,
                from,
                until,
            } => Command::SearchChatMessages {
                chat,
                query,
                from,
                until,
            },

            Self::SendText {
                chat,
                text,
                quoting,
                mentions,
            } => Command::SendText {
                chat,
                text,
                quoting,
                mentions,
            },
            Self::SendFiles {
                chat,
                paths,
                caption,
                mentions,
                quoting,
            } => Command::SendFiles {
                chat,
                paths: paths.into_iter().map(PathBuf::from).collect(),
                caption,
                mentions,
                quoting,
            },
            Self::SendVoice {
                chat,
                samples,
                quoting,
            } => Command::SendVoice {
                chat,
                samples,
                quoting,
            },
            Self::EditText {
                chat,
                id,
                text,
                mentions,
            } => Command::EditText {
                chat,
                id,
                text,
                mentions,
            },
            Self::CreatePoll { chat, draft } => Command::CreatePoll {
                chat,
                draft: draft.into(),
            },
            Self::VotePoll {
                chat,
                message,
                choices,
            } => Command::VotePoll {
                chat,
                message,
                choices: choices.into_iter().map(|choice| choice as usize).collect(),
            },
            Self::RefreshPoll { chat, message } => Command::RefreshPoll { chat, message },
            Self::React {
                chat,
                message,
                emoji,
            } => Command::React {
                chat,
                message,
                emoji,
            },
            Self::Revoke { chat, id } => Command::Revoke { chat, id },
            Self::DeleteLocal { chat, id } => Command::DeleteLocal { chat, id },
            Self::Forward {
                from_chat,
                messages,
                to_chat,
            } => Command::Forward {
                from_chat,
                messages,
                to_chat,
            },
            Self::Composing { chat, composing } => Command::Composing { chat, composing },
            Self::SaveDraft { chat, text } => Command::SaveDraft { chat, text },

            Self::SetArchived { chat, archived } => Command::SetArchived(chat, archived),
            Self::SetPinned { chat, pinned } => Command::SetPinned(chat, pinned),
            Self::SetFavorite { chat, favorite } => Command::SetFavorite(chat, favorite),
            Self::SetMuted { chat, until } => Command::SetMuted(chat, until),
            Self::ClearChat { chat } => Command::ClearChat(chat),
            Self::DeleteChat { chat } => Command::DeleteChat(chat),
            Self::EnsureChat { chat, name } => Command::EnsureChat { chat, name },

            Self::RecentStickers => Command::RecentStickers,
            Self::SendSticker {
                chat,
                path,
                quoting,
            } => Command::SendSticker {
                chat,
                path: path.into(),
                quoting,
            },
            Self::SaveSticker { path } => Command::SaveSticker { path: path.into() },
            Self::ForgetSticker { path } => Command::ForgetSticker { path: path.into() },
            Self::RemoveRecentSticker { path } => {
                Command::RemoveRecentSticker { path: path.into() }
            }
            Self::SearchGifs { query, key } => Command::SearchGifs { query, key },
            Self::SendGif { chat, gif, quoting } => Command::SendGif {
                chat,
                gif: gif.into(),
                quoting,
            },

            Self::SetProfile { name, about } => Command::SetProfile { name, about },
            Self::SetProfilePicture { jpeg } => Command::SetProfilePicture(jpeg),

            Self::SetGroupName { chat, name } => Command::SetGroupName { chat, name },
            Self::SetGroupPicture { chat, jpeg } => Command::SetGroupPicture { chat, jpeg },
            Self::LeaveGroup { chat, archive } => Command::LeaveGroup { chat, archive },
            Self::NewContact {
                phone,
                full_name,
                first_name,
                to_phone,
            } => Command::NewContact {
                phone,
                full_name,
                first_name,
                to_phone,
            },
            Self::SaveContact {
                id,
                full_name,
                first_name,
                to_phone,
            } => Command::SaveContact {
                id,
                full_name,
                first_name,
                to_phone,
            },
        }
    }
}
