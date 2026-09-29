//! Commands Swift may send, and their upstream equivalents.
//!
//! This is a deliberate subset: a command is added when a screen needs it.
//! Upstream's internal result commands (`Sent`, `Downloaded`, …) are never
//! exposed. File pickers are native on the Swift side, so the `Pick*`
//! commands are replaced by their path-carrying counterparts.

use std::path::PathBuf;

use zapfast::backend::Command;

use crate::types::PageKey;

#[derive(Debug, Clone, uniffi::Enum)]
pub enum BridgeCommand {
    // Link
    /// Pair by phone number instead of QR; the phone shows a code prompt.
    PairWithPhone { phone: String },
    Reconnect,
    /// Unlink this device here and on the phone.
    Unlink,
    /// Set aside an unreadable archive and start over with a new link.
    StartOverArchive,
    /// Whether the person is looking at the app.
    SetOnline { online: bool },
    /// Empty follows the system.
    SetProxy { proxy: String },

    // Reading
    /// Archived messages before `before`, or the newest page.
    LoadChat { chat: String, before: Option<PageKey> },
    /// Ask the phone for messages older than the archive has.
    FetchOlder { chat: String },
    MarkRead { chat: String, receipts: bool },
    MarkUnread { chat: String },
    Download { chat: String, message: String, card: Option<u32> },
    /// A voice message was played: the blue microphone for its sender.
    MarkPlayed {
        chat: String,
        message: String,
        sender: String,
        receipts: bool,
    },
    FetchAvatar { id: String, full: bool },
    SearchMessages { query: String },
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
    EditText {
        chat: String,
        id: String,
        text: String,
        mentions: Vec<String>,
    },
    React { chat: String, message: String, emoji: String },
    /// Delete for everyone.
    Revoke { chat: String, id: String },
    /// Delete for me.
    DeleteLocal { chat: String, id: String },
    Forward {
        from_chat: String,
        messages: Vec<String>,
        to_chat: String,
    },
    Composing { chat: String, composing: bool },
    SaveDraft { chat: String, text: String },

    // Chat management
    SetArchived { chat: String, archived: bool },
    SetPinned { chat: String, pinned: bool },
    SetFavorite { chat: String, favorite: bool },
    /// Mute end in Unix seconds, `Some(0)` indefinitely, `None` unmutes.
    SetMuted { chat: String, until: Option<i64> },
    ClearChat { chat: String },
    DeleteChat { chat: String },
    /// Create an archive chat before its first message.
    EnsureChat { chat: String, name: String },
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
        }
    }
}
