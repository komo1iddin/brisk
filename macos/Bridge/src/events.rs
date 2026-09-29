//! Upstream events, as Swift receives them.
//!
//! `convert` matches every upstream variant by name, with no wildcard. When
//! upstream adds an event, the bridge stops compiling until someone decides
//! whether Swift needs it: map it, or list it under "not bridged yet".

use zapfast::backend::{Event, Refusal, Unsent};

use crate::types::{
    ChatSummary, ContactRecord, GifFailure, GifInfo, LinkState, MessageRecord, StickerLibrary,
    count, path_string,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SendRefusal {
    /// No WhatsApp connection.
    Offline,
    /// The quoted message cannot be quoted any more.
    QuoteUnavailable,
}

impl From<Refusal> for SendRefusal {
    fn from(refusal: Refusal) -> Self {
        match refusal {
            Refusal::Offline => Self::Offline,
            Refusal::QuoteUnavailable => Self::QuoteUnavailable,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Draft {
    pub chat: String,
    pub text: String,
}

#[derive(Clone, uniffi::Enum)]
pub enum BridgeEvent {
    Link {
        state: LinkState,
    },
    /// The linked account.
    Me {
        id: String,
        lid: Option<String>,
        name: Option<String>,
        about: Option<String>,
    },
    /// The full chat list, newest first.
    Chats {
        chats: Vec<ChatSummary>,
    },
    ChatUpdated {
        chat: ChatSummary,
    },
    ChatRemoved {
        chat: String,
    },
    ChatCleared {
        chat: String,
        through: i64,
    },
    /// Unsent text per chat, once at startup.
    Drafts {
        drafts: Vec<Draft>,
    },
    /// Messages in ascending order. `older` prepends; `complete` means the
    /// archive has nothing earlier.
    Messages {
        chat: String,
        messages: Vec<MessageRecord>,
        older: bool,
        complete: bool,
    },
    MessageUpdated {
        message: MessageRecord,
    },
    MessageDeleted {
        chat: String,
        id: String,
    },
    /// A live incoming message, for notifications.
    Incoming {
        chat: String,
        message: MessageRecord,
    },
    Contacts {
        contacts: Vec<ContactRecord>,
    },
    SearchHits {
        query: String,
        messages: Vec<MessageRecord>,
    },
    ChatHits {
        chat: String,
        query: String,
        from: Option<i64>,
        until: Option<i64>,
        messages: Vec<MessageRecord>,
        truncated: bool,
    },
    /// A new poll went out, or failed with `error`.
    PollCreated {
        chat: String,
        error: Option<String>,
    },
    /// A vote went out, or failed with `error`.
    PollVoted {
        chat: String,
        message: String,
        error: Option<String>,
    },
    /// A change to a group's name or photo went out (`saving`), or
    /// WhatsApp answered it.
    GroupSaving {
        chat: String,
        saving: bool,
    },
    /// The picker's stickers.
    Stickers {
        library: StickerLibrary,
    },
    /// GIF results for `query`, or why there are none.
    Gifs {
        query: String,
        gifs: Vec<GifInfo>,
        error: Option<GifFailure>,
    },
    /// A number checked by `NewContact` is on WhatsApp; its chat can open.
    ContactReady {
        id: String,
        name: Option<String>,
    },
    Typing {
        chat: String,
        sender: String,
        composing: bool,
    },
    Presence {
        id: String,
        online: bool,
        last_seen: Option<i64>,
    },
    Avatar {
        id: String,
        full: bool,
        path: Option<String>,
    },
    /// An attachment finished downloading, or failed.
    Media {
        chat: String,
        message: String,
        card: Option<u32>,
        path: Option<String>,
        error: Option<String>,
    },
    Syncing {
        active: bool,
    },
    SyncProgress {
        percent: u32,
    },
    OlderFetched {
        chat: String,
        more: bool,
    },
    ReceiptsPrivacy {
        disabled: bool,
    },
    PinLimit {
        limit: u32,
    },
    /// A send was refused before leaving this computer. `text` is the
    /// composer text to restore, when it was a text message.
    SendRefused {
        chat: String,
        quoting: Option<String>,
        reason: SendRefusal,
        text: Option<String>,
    },
    Info {
        message: String,
    },
    Error {
        message: String,
    },
    /// An upstream event the macOS app does not handle yet.
    NotBridged {
        name: String,
    },
}

pub(crate) fn convert(event: Event) -> Option<BridgeEvent> {
    use BridgeEvent as B;
    let not_bridged = |name: &str| Some(B::NotBridged { name: name.into() });
    match event {
        Event::Link(status) => Some(B::Link {
            state: status.into(),
        }),
        Event::Me {
            id,
            lid,
            name,
            about,
        } => Some(B::Me {
            id,
            lid,
            name,
            about,
        }),
        Event::Chats(chats) => Some(B::Chats {
            chats: chats.into_iter().map(Into::into).collect(),
        }),
        Event::ChatUpdated(chat) => Some(B::ChatUpdated {
            chat: (*chat).into(),
        }),
        Event::ChatRemoved { chat } => Some(B::ChatRemoved { chat }),
        Event::ChatCleared { chat, through } => Some(B::ChatCleared { chat, through }),
        Event::Drafts(drafts) => Some(B::Drafts {
            drafts: drafts
                .into_iter()
                .map(|(chat, text)| Draft { chat, text })
                .collect(),
        }),
        Event::Messages {
            chat,
            messages,
            older,
            complete,
        } => Some(B::Messages {
            chat,
            messages: messages.into_iter().map(Into::into).collect(),
            older,
            complete,
        }),
        Event::MessageUpdated(message) => Some(B::MessageUpdated {
            message: message.into(),
        }),
        Event::MessageDeleted { chat, id } => Some(B::MessageDeleted { chat, id }),
        Event::Incoming { chat, message } => Some(B::Incoming {
            chat,
            message: message.into(),
        }),
        Event::Contacts(contacts) => Some(B::Contacts {
            contacts: contacts.into_iter().map(Into::into).collect(),
        }),
        Event::SearchHits { query, messages } => Some(B::SearchHits {
            query,
            messages: messages.into_iter().map(Into::into).collect(),
        }),
        Event::ChatHits {
            chat,
            query,
            from,
            until,
            messages,
            truncated,
        } => Some(B::ChatHits {
            chat,
            query,
            from,
            until,
            messages: messages.into_iter().map(Into::into).collect(),
            truncated,
        }),
        Event::PollCreated { chat, error } => Some(B::PollCreated { chat, error }),
        Event::PollVoted {
            chat,
            message,
            error,
        } => Some(B::PollVoted {
            chat,
            message,
            error,
        }),
        Event::GroupSaving { chat, saving } => Some(B::GroupSaving { chat, saving }),
        Event::Stickers {
            favorites,
            packs,
            recent,
            received,
            emojis,
        } => Some(B::Stickers {
            library: StickerLibrary::new(favorites, packs, recent, received, emojis),
        }),
        Event::Gifs { query, results } => Some(match results {
            Ok(gifs) => B::Gifs {
                query,
                gifs: gifs.into_iter().map(Into::into).collect(),
                error: None,
            },
            Err(error) => B::Gifs {
                query,
                gifs: Vec::new(),
                error: Some(error.into()),
            },
        }),
        Event::ContactReady { id, name } => Some(B::ContactReady { id, name }),
        Event::Typing {
            chat,
            sender,
            composing,
        } => Some(B::Typing {
            chat,
            sender,
            composing,
        }),
        Event::Presence {
            id,
            online,
            last_seen,
        } => Some(B::Presence {
            id,
            online,
            last_seen,
        }),
        Event::Avatar { id, full, path } => Some(B::Avatar {
            id,
            full,
            path: path.map(path_string),
        }),
        Event::Media {
            card,
            chat,
            message,
            result,
        } => {
            let (path, error) = match result {
                Ok(path) => (Some(path_string(path)), None),
                Err(error) => (None, Some(error)),
            };
            Some(B::Media {
                chat,
                message,
                card: card.map(count),
                path,
                error,
            })
        }
        Event::Syncing(active) => Some(B::Syncing { active }),
        Event::SyncProgress(percent) => Some(B::SyncProgress { percent }),
        Event::OlderFetched { chat, more } => Some(B::OlderFetched { chat, more }),
        Event::ReceiptsPrivacy { disabled } => Some(B::ReceiptsPrivacy { disabled }),
        Event::PinLimit(limit) => Some(B::PinLimit {
            limit: count(limit),
        }),
        Event::SendRefused {
            chat,
            quoting,
            unsent,
            reason,
        } => Some(B::SendRefused {
            chat,
            quoting,
            reason: reason.into(),
            text: match unsent {
                Unsent::Text(text) => Some(text),
                Unsent::Voice(_)
                | Unsent::Files { .. }
                | Unsent::Image { .. }
                | Unsent::Sticker
                | Unsent::Gif => None,
            },
        }),
        Event::Info(message) => Some(B::Info { message }),
        Event::Error(message) => Some(B::Error { message }),

        // Not bridged yet. Each moves up when its feature lands on macOS.
        Event::InteractiveReplyState { .. } => not_bridged("InteractiveReplyState"),
        Event::Labels(_) => not_bridged("Labels"),
        Event::Picked { .. } => not_bridged("Picked"),
        Event::StickerPicture { .. } => not_bridged("StickerPicture"),
        Event::StickerPackPreview(_) => not_bridged("StickerPackPreview"),
        Event::AccountPrivacy { .. } => not_bridged("AccountPrivacy"),
        Event::AccountPrivacySaved { .. } => not_bridged("AccountPrivacySaved"),
        Event::AccountPrivacyFailed { .. } => not_bridged("AccountPrivacyFailed"),
        Event::Receipts(_) => not_bridged("Receipts"),
        Event::ChatSoundPicked { .. } => not_bridged("ChatSoundPicked"),
        Event::DownloadFolderPicked(_) => not_bridged("DownloadFolderPicked"),
        Event::WallpaperImagePicked(_) => not_bridged("WallpaperImagePicked"),
        Event::NotificationSoundPicked { .. } => not_bridged("NotificationSoundPicked"),
        Event::InvitePreview { .. } => not_bridged("InvitePreview"),
        Event::InviteJoined { .. } => not_bridged("InviteJoined"),
        Event::ClipboardImage(_) => not_bridged("ClipboardImage"),
        // Upstream's self-updater targets its own binary, never this app.
        Event::UpdateAvailable { .. }
        | Event::UpdateSupport(_)
        | Event::UpdateProgress { .. }
        | Event::UpdateDownloaded(_)
        | Event::UpdateInstalling(_) => None,
    }
}
