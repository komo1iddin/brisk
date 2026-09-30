//! Commands Swift may send, and their upstream equivalents.
//!
//! This is a deliberate subset: a command is added when a screen needs it.
//! Upstream's internal result commands (`Sent`, `Downloaded`, …) are never
//! exposed. File pickers are native on the Swift side, so the `Pick*`
//! commands are replaced by their path-carrying counterparts, except
//! `PickStickerArchive`: upstream imports a `.wastickers` archive only from
//! its own picker (the system's open panel through rfd), with no command
//! that takes a path.

use std::path::PathBuf;

use zapfast::backend::Command;

use crate::types::{
    GifInfo, NotificationSoundInfo, PageKey, PollDraftInfo, PrivacyChoiceInfo, PrivacyKindInfo,
    StickerCropInfo,
};

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
    /// Where new downloads go; `None` keeps them in the media cache.
    /// Files already downloaded stay where they are.
    SetDownloadFolder {
        path: Option<String>,
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
    /// Follow one of our group messages' receipts while its "Message info"
    /// is open; answered by `Receipts` now and on every new receipt.
    WatchReceipts {
        chat: String,
        message: String,
    },
    /// Stop following receipts.
    StopWatchingReceipts,
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
    /// A pasted image as straight-alpha RGBA, `width * height * 4` bytes;
    /// the worker encodes it as a JPEG photo.
    SendImage {
        chat: String,
        width: u32,
        height: u32,
        rgba: Vec<u8>,
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
    /// Answers a business message: `button` is the index of a visible
    /// button, `choice` the index of a list option. The worker re-reads the
    /// ids from the archived message; answered by `InteractiveReplyState`.
    ReplyInteractive {
        chat: String,
        message: String,
        button: u32,
        choice: Option<u32>,
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
    /// A chat's own notification sound, kept in the archive; `None`
    /// follows Settings again.
    SetChatSound {
        chat: String,
        sound: Option<NotificationSoundInfo>,
    },
    /// WhatsApp's chat lock, synced with the phone.
    SetLocked {
        chat: String,
        locked: bool,
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

    // Labels (on this computer only)
    CreateLabel {
        name: String,
        color_hex: String,
    },
    /// Renames and recolours a label.
    UpdateLabel {
        id: String,
        name: String,
        color_hex: String,
    },
    /// Deletes a label and takes it off every chat.
    DeleteLabel {
        id: String,
    },
    /// Replaces the labels one chat wears.
    SetChatLabels {
        chat: String,
        labels: Vec<String>,
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
    /// Downloads a sticker pack shared in a chat so it can be viewed;
    /// answered by `StickerPackPreview`.
    ViewStickerPack {
        chat: String,
        message: String,
    },
    /// Copies a viewed pack into the packs here.
    AddStickerPack {
        dir: String,
        name: String,
    },
    /// Sends a pack as a WhatsApp sticker pack message.
    SendStickerPack {
        chat: String,
        dir: String,
    },
    /// Creates an empty pack of our own.
    CreateStickerPack {
        name: String,
    },
    /// Files a sticker into one of our packs, or takes it out.
    SetStickerPack {
        pack: String,
        sticker: String,
        member: bool,
    },
    /// Deletes one of the packs here.
    DeleteStickerPack {
        dir: String,
    },
    /// Imports a pack from a signal.art link.
    ImportStickerUrl {
        url: String,
    },
    /// Asks for a `.wastickers` or `.zip` sticker archive in the system's
    /// open panel and adds it as a pack; the result arrives as Info or
    /// Error and a new sticker library.
    PickStickerArchive,
    /// Makes a sticker from a picture: sends it to `chat`, or without one
    /// adds it to Favorites.
    MakeSticker {
        source: String,
        crop: StickerCropInfo,
        transparent: bool,
        emojis: Vec<String>,
        chat: Option<String>,
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

    // Account privacy (kept on the phone)
    /// Asks the phone for the privacy values; answered by `AccountPrivacy`.
    FetchAccountPrivacy,
    /// Writes one category; answered by `AccountPrivacySaved` or `…Failed`.
    SetAccountPrivacy {
        kind: PrivacyKindInfo,
        choice: PrivacyChoiceInfo,
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
    /// Looks up the group behind an invite code; answered by `InvitePreview`.
    PreviewInvite {
        code: String,
    },
    /// Joins the group behind an invite code; answered by `InviteJoined`.
    JoinInvite {
        code: String,
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
            Self::SetDownloadFolder { path } => {
                Command::SetDownloadFolder(path.map(std::path::PathBuf::from))
            }

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
            Self::WatchReceipts { chat, message } => Command::WatchReceipts(Some((chat, message))),
            Self::StopWatchingReceipts => Command::WatchReceipts(None),
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
            Self::SendImage {
                chat,
                width,
                height,
                rgba,
                caption,
                mentions,
                quoting,
            } => Command::SendImage {
                chat,
                width,
                height,
                rgba,
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
            Self::ReplyInteractive {
                chat,
                message,
                button,
                choice,
            } => Command::ReplyInteractive {
                chat,
                message,
                button: button as usize,
                choice: choice.map(|choice| choice as usize),
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
            Self::SetChatSound { chat, sound } => Command::SetChatSound {
                chat,
                sound: sound.map(Into::into),
            },
            Self::SetLocked { chat, locked } => Command::SetLocked(chat, locked),
            Self::SetMuted { chat, until } => Command::SetMuted(chat, until),
            Self::ClearChat { chat } => Command::ClearChat(chat),
            Self::DeleteChat { chat } => Command::DeleteChat(chat),
            Self::EnsureChat { chat, name } => Command::EnsureChat { chat, name },

            Self::CreateLabel { name, color_hex } => Command::CreateLabel { name, color_hex },
            Self::UpdateLabel {
                id,
                name,
                color_hex,
            } => Command::UpdateLabel {
                id,
                name,
                color_hex,
            },
            Self::DeleteLabel { id } => Command::DeleteLabel(id),
            Self::SetChatLabels { chat, labels } => Command::SetChatLabels { chat, labels },

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
            Self::ViewStickerPack { chat, message } => Command::ViewStickerPack { chat, message },
            Self::AddStickerPack { dir, name } => Command::AddStickerPack {
                dir: dir.into(),
                name,
            },
            Self::SendStickerPack { chat, dir } => Command::SendStickerPack {
                chat,
                dir: dir.into(),
            },
            Self::CreateStickerPack { name } => Command::CreateStickerPack { name },
            Self::SetStickerPack {
                pack,
                sticker,
                member,
            } => Command::SetStickerPack {
                pack: pack.into(),
                sticker: sticker.into(),
                member,
            },
            Self::DeleteStickerPack { dir } => Command::DeleteStickerPack { dir: dir.into() },
            Self::ImportStickerUrl { url } => Command::ImportStickerUrl { url },
            Self::PickStickerArchive => Command::PickStickerArchive,
            Self::MakeSticker {
                source,
                crop,
                transparent,
                emojis,
                chat,
            } => Command::MakeSticker {
                source: source.into(),
                crop: crop.into(),
                transparent,
                emojis,
                chat,
            },
            Self::SearchGifs { query, key } => Command::SearchGifs { query, key },
            Self::SendGif { chat, gif, quoting } => Command::SendGif {
                chat,
                gif: gif.into(),
                quoting,
            },

            Self::SetProfile { name, about } => Command::SetProfile { name, about },
            Self::SetProfilePicture { jpeg } => Command::SetProfilePicture(jpeg),

            Self::FetchAccountPrivacy => Command::FetchAccountPrivacy,
            Self::SetAccountPrivacy { kind, choice } => Command::SetAccountPrivacy {
                kind: kind.into(),
                choice: choice.into(),
            },

            Self::SetGroupName { chat, name } => Command::SetGroupName { chat, name },
            Self::SetGroupPicture { chat, jpeg } => Command::SetGroupPicture { chat, jpeg },
            Self::LeaveGroup { chat, archive } => Command::LeaveGroup { chat, archive },
            Self::PreviewInvite { code } => Command::PreviewInvite(code),
            Self::JoinInvite { code } => Command::JoinInvite(code),
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
