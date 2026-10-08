use zapfast::model::{
    Content, LinkPreview, Media, MentionRef, Message, OnceMedia, PollState, PollVoter, Quoted,
    Reaction,
};

use super::{DeliveryState, InteractiveCardInfo, count, path_string};

/// Page boundary: the oldest loaded message's timestamp and id.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PageKey {
    pub timestamp: i64,
    pub id: String,
}

impl From<PageKey> for zapfast::backend::PageKey {
    fn from(key: PageKey) -> Self {
        (key.timestamp, key.id)
    }
}

/// Attachment metadata. Download keys stay in the archive.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaInfo {
    pub mime: String,
    /// Declared size in bytes; zero when unknown.
    pub size: u64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// Decrypted local file, once downloaded.
    pub path: Option<String>,
}

impl From<Media> for MediaInfo {
    fn from(media: Media) -> Self {
        // `state` is interface-side download progress; Swift tracks its own.
        let Media {
            mime,
            size,
            width,
            height,
            path,
            state: _,
        } = media;
        Self {
            mime,
            size,
            width,
            height,
            path: path.map(path_string),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LinkPreviewInfo {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
}

impl From<LinkPreview> for LinkPreviewInfo {
    fn from(preview: LinkPreview) -> Self {
        let LinkPreview {
            url,
            title,
            description,
        } = preview;
        Self {
            url,
            title,
            description,
        }
    }
}

/// A raw `@user` mention token and the canonical id it names.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MentionInfo {
    pub user: String,
    pub id: String,
}

impl From<MentionRef> for MentionInfo {
    fn from(mention: MentionRef) -> Self {
        let MentionRef { user, id } = mention;
        Self { user, id }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QuotedMessage {
    pub id: String,
    pub sender: String,
    pub sender_name: Option<String>,
    pub summary: String,
    pub mentions: Vec<MentionInfo>,
}

impl From<Quoted> for QuotedMessage {
    fn from(quoted: Quoted) -> Self {
        let Quoted {
            id,
            sender,
            sender_name,
            summary,
            mentions,
        } = quoted;
        Self {
            id,
            sender,
            sender_name,
            summary,
            mentions: mentions.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ReactionInfo {
    pub sender: String,
    pub from_me: bool,
    pub emoji: String,
}

impl From<Reaction> for ReactionInfo {
    fn from(reaction: Reaction) -> Self {
        let Reaction {
            sender,
            from_me,
            emoji,
        } = reaction;
        Self {
            sender,
            from_me,
            emoji,
        }
    }
}

/// Poll results safe for the interface. Keys stay in the worker.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PollSummary {
    /// How many options one vote may pick.
    pub selectable: u32,
    /// Votes per option, in option order.
    pub counts: Vec<u32>,
    /// Our own choices.
    pub selected: Vec<u32>,
    pub voters: u32,
    pub can_vote: bool,
    pub history_complete: bool,
    /// Earlier votes should be asked of the phone while the poll is seen.
    pub refresh_needed: bool,
    pub refreshing: bool,
    pub refresh_failed: bool,
    /// The latest decrypted vote of each voter, for the results sheet.
    pub votes: Vec<PollVoterInfo>,
}

/// One person's latest vote.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PollVoterInfo {
    pub id: String,
    pub name: String,
    pub from_me: bool,
    pub timestamp: i64,
    /// Option indices chosen.
    pub choices: Vec<u32>,
}

impl From<PollVoter> for PollVoterInfo {
    fn from(voter: PollVoter) -> Self {
        let PollVoter {
            id,
            name,
            from_me,
            timestamp,
            choices,
        } = voter;
        Self {
            id,
            name,
            from_me,
            timestamp,
            choices: choices.into_iter().map(count).collect(),
        }
    }
}

impl From<PollState> for PollSummary {
    fn from(state: PollState) -> Self {
        let PollState {
            selectable,
            counts,
            selected,
            voters,
            can_vote,
            history_complete,
            refresh_needed,
            refreshing,
            refresh_failed,
            votes,
        } = state;
        Self {
            selectable: count(selectable),
            counts: counts.into_iter().map(count).collect(),
            selected: selected.into_iter().map(count).collect(),
            voters: count(voters),
            can_vote,
            history_complete,
            refresh_needed,
            refreshing,
            refresh_failed,
            votes: votes.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OnceMediaKind {
    Photo,
    Video,
    Voice,
    Audio,
}

impl From<OnceMedia> for OnceMediaKind {
    fn from(kind: OnceMedia) -> Self {
        match kind {
            OnceMedia::Photo => Self::Photo,
            OnceMedia::Video => Self::Video,
            OnceMedia::Voice => Self::Voice,
            OnceMedia::Audio => Self::Audio,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum MessageContent {
    Text {
        text: String,
        preview: Option<LinkPreviewInfo>,
    },
    /// Buttons, lists and cards. `text` is the whole readable text;
    /// `card`, when parsed, has the body and actions apart.
    Interactive {
        text: String,
        card: Option<InteractiveCardInfo>,
    },
    Image {
        caption: Option<String>,
        media: MediaInfo,
    },
    Video {
        caption: Option<String>,
        media: MediaInfo,
        seconds: Option<u32>,
        gif: bool,
        /// Round video message.
        note: bool,
    },
    Audio {
        media: MediaInfo,
        seconds: Option<u32>,
        voice_note: bool,
        /// 64-bar waveform from the sender.
        waveform: Vec<u8>,
    },
    Document {
        media: MediaInfo,
        file_name: String,
        caption: Option<String>,
        pages: Option<u32>,
    },
    Sticker {
        media: MediaInfo,
        animated: bool,
    },
    StickerPack {
        name: String,
        publisher: String,
        count: u32,
        caption: Option<String>,
    },
    Location {
        latitude: f64,
        longitude: f64,
        name: Option<String>,
        address: Option<String>,
    },
    LiveLocation {
        latitude: f64,
        longitude: f64,
        accuracy_m: Option<u32>,
        speed_mps: Option<f32>,
        heading_deg: Option<u32>,
        ended: bool,
        /// Unix seconds of the latest position, zero before any update.
        updated: i64,
    },
    Contact {
        display_name: String,
        vcard: String,
    },
    Poll {
        question: String,
        options: Vec<String>,
        state: PollSummary,
    },
    Revoked,
    Unsupported {
        what: String,
    },
    /// Delivered only to the phone, such as view-once media.
    PhoneOnly {
        view_once: bool,
        live_location: bool,
        once: Option<OnceMediaKind>,
    },
}

impl From<Content> for MessageContent {
    fn from(content: Content) -> Self {
        match content {
            Content::Text { text, preview } => Self::Text {
                text,
                preview: preview.map(Into::into),
            },
            Content::Interactive { text, card } => Self::Interactive {
                text,
                card: card.map(|card| (*card).into()),
            },
            Content::Image { caption, media } => Self::Image {
                caption,
                media: media.into(),
            },
            Content::Video {
                caption,
                media,
                seconds,
                gif,
                note,
            } => Self::Video {
                caption,
                media: media.into(),
                seconds,
                gif,
                note,
            },
            Content::Audio {
                media,
                seconds,
                voice_note,
                waveform,
            } => Self::Audio {
                media: media.into(),
                seconds,
                voice_note,
                waveform,
            },
            Content::Document {
                media,
                file_name,
                caption,
                pages,
            } => Self::Document {
                media: media.into(),
                file_name,
                caption,
                pages,
            },
            Content::Sticker { media, animated } => Self::Sticker {
                media: media.into(),
                animated,
            },
            Content::StickerPack {
                name,
                publisher,
                count,
                caption,
            } => Self::StickerPack {
                name,
                publisher,
                count,
                caption,
            },
            Content::Location {
                latitude,
                longitude,
                name,
                address,
            } => Self::Location {
                latitude,
                longitude,
                name,
                address,
            },
            Content::LiveLocation {
                latitude,
                longitude,
                accuracy_m,
                speed_mps,
                heading_deg,
                sequence: _,
                ended,
                updated,
            } => Self::LiveLocation {
                latitude,
                longitude,
                accuracy_m,
                speed_mps,
                heading_deg,
                ended,
                updated,
            },
            Content::Contact {
                display_name,
                vcard,
            } => Self::Contact {
                display_name,
                vcard,
            },
            Content::Poll {
                question,
                options,
                state,
            } => Self::Poll {
                question,
                options,
                state: state.into(),
            },
            Content::Revoked => Self::Revoked,
            Content::Unsupported { what } => Self::Unsupported { what },
            Content::PhoneOnly {
                view_once,
                live_location,
                once,
            } => Self::PhoneOnly {
                view_once,
                live_location,
                once: once.map(Into::into),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MessageRecord {
    /// WhatsApp message id, unique within its chat.
    pub id: String,
    pub chat: String,
    /// Sender id, ours for outgoing messages.
    pub sender: String,
    /// Group sender's push name when received.
    pub sender_name: Option<String>,
    pub from_me: bool,
    /// Unix seconds.
    pub timestamp: i64,
    pub content: MessageContent,
    pub status: DeliveryState,
    pub delivered_at: Option<i64>,
    pub read_at: Option<i64>,
    pub quoted: Option<QuotedMessage>,
    pub reactions: Vec<ReactionInfo>,
    pub edited: bool,
    pub mentions: Vec<MentionInfo>,
    pub forwarded: bool,
    /// JPEG preview sent with an attachment or link.
    pub thumbnail: Option<Vec<u8>>,
    /// One-line summary for chat rows and quotes.
    pub summary: String,
}

impl From<Message> for MessageRecord {
    fn from(message: Message) -> Self {
        let summary = message.summary();
        let Message {
            id,
            chat,
            sender,
            sender_name,
            from_me,
            timestamp,
            // The archive already pages in the phone's order.
            history_order: _,
            content,
            status,
            delivered_at,
            read_at,
            quoted,
            reactions,
            edited,
            mentions,
            forwarded,
            thumbnail,
        } = message;
        Self {
            id,
            chat,
            sender,
            sender_name,
            from_me,
            timestamp,
            content: content.into(),
            status: status.into(),
            delivered_at,
            read_at,
            quoted: quoted.map(Into::into),
            reactions: reactions.into_iter().map(Into::into).collect(),
            edited,
            mentions: mentions.into_iter().map(Into::into).collect(),
            forwarded,
            thumbnail,
            summary,
        }
    }
}

impl From<Box<Message>> for MessageRecord {
    fn from(message: Box<Message>) -> Self {
        (*message).into()
    }
}

/// A poll being written, before it is sent.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PollDraftInfo {
    pub question: String,
    pub options: Vec<String>,
    /// More than one answer may be chosen.
    pub multiple: bool,
}

impl From<PollDraftInfo> for zapfast::model::PollDraft {
    fn from(draft: PollDraftInfo) -> Self {
        let PollDraftInfo {
            question,
            options,
            multiple,
        } = draft;
        Self {
            question,
            options,
            multiple,
        }
    }
}
