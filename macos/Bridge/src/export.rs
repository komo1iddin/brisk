//! Reading a whole chat out of the archive, for "Export Chat".
//!
//! The worker owns the live archive and hands the interface only what it is
//! showing. An export needs every message, and must not disturb the open
//! timeline, so it reads through a connection of its own. SQLite lets a WAL
//! database be read while the worker writes to it.
//!
//! This only reads. Nothing here decides what an export looks like: Swift
//! formats the messages, so dates and wording follow the reader's language.
//!
//! The same reader answers "what does this chat have that this Mac does not"
//! for downloading from the phone: [`ChatReader::census`] walks the chat once
//! and lists its attachments with whether each is here.

use std::sync::Mutex;

use zapfast::archive::Archive;

use crate::client::BridgeError;
use crate::types::{MessageRecord, PageKey};

/// One open connection to the archive, held for the length of an export.
#[derive(uniffi::Object)]
pub struct ChatReader {
    archive: Mutex<Archive>,
}

/// What kind of attachment a message carries, as downloading from the phone
/// groups them. Stickers are not here: they download by themselves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChatMediaKind {
    Photo,
    Video,
    Voice,
    Audio,
    Document,
}

/// One attachment of a chat.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatMedia {
    pub message: String,
    pub timestamp: i64,
    pub kind: ChatMediaKind,
    /// The size the sender declared, in bytes.
    pub size: u64,
    /// The file is on this Mac.
    pub here: bool,
}

/// What a chat holds on this Mac.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatCensus {
    pub messages: u64,
    /// When the oldest message was sent, in Unix seconds.
    pub oldest: Option<i64>,
    /// Every attachment, newest first.
    pub media: Vec<ChatMedia>,
}

/// How many messages one read of the archive returns.
const CENSUS_PAGE: usize = 500;

impl ChatReader {
    pub(crate) fn new(archive: Archive) -> Self {
        Self {
            archive: Mutex::new(archive),
        }
    }

    fn read(
        &self,
        chat: &str,
        before: Option<PageKey>,
        limit: u32,
    ) -> Result<Vec<MessageRecord>, BridgeError> {
        let archive = self.archive.lock().unwrap_or_else(|p| p.into_inner());
        let before = before.map(|key| (key.timestamp, key.id));
        let page = archive
            .messages(
                chat,
                before.as_ref().map(|(time, id)| (*time, id.as_str())),
                limit as usize,
            )
            .map_err(|error| BridgeError::Archive {
                message: error.to_string(),
            })?;
        Ok(page.into_iter().map(Into::into).collect())
    }
}

#[uniffi::export]
impl ChatReader {
    /// Up to `limit` messages of `chat` older than `before` (the newest ones
    /// when there is no boundary), oldest first. Passing the first message of
    /// the previous page as the boundary walks a chat back to its start; an
    /// empty page means there is nothing older.
    pub fn page(
        &self,
        chat: String,
        before: Option<PageKey>,
        limit: u32,
    ) -> Result<Vec<MessageRecord>, BridgeError> {
        self.read(&chat, before, limit)
    }

    /// Walks `chat` from its newest message to its first and lists what it
    /// holds: how many messages, since when, and each attachment with whether
    /// its file is on this Mac. Does blocking work for a long chat: call it
    /// off the main thread.
    pub fn census(&self, chat: String) -> Result<ChatCensus, BridgeError> {
        let mut census = ChatCensus {
            messages: 0,
            oldest: None,
            media: Vec::new(),
        };
        let mut before: Option<PageKey> = None;
        loop {
            let page = self.read(&chat, before.take(), CENSUS_PAGE as u32)?;
            let Some(first) = page.first() else { break };
            before = Some(PageKey {
                timestamp: first.timestamp,
                id: first.id.clone(),
            });
            census.messages += page.len() as u64;
            census.oldest = Some(
                census
                    .oldest
                    .map_or(first.timestamp, |t| t.min(first.timestamp)),
            );
            let full = page.len() >= CENSUS_PAGE;
            // Pages are oldest first; the census lists the newest first.
            census.media.extend(page.iter().rev().filter_map(media_of));
            if !full {
                break;
            }
        }
        Ok(census)
    }
}

/// The attachment a message carries, if it carries one worth fetching.
fn media_of(message: &MessageRecord) -> Option<ChatMedia> {
    let (kind, media) = match &message.content {
        crate::types::MessageContent::Image { media, .. } => (ChatMediaKind::Photo, media),
        crate::types::MessageContent::Video { media, .. } => (ChatMediaKind::Video, media),
        crate::types::MessageContent::Audio {
            media, voice_note, ..
        } => (
            if *voice_note {
                ChatMediaKind::Voice
            } else {
                ChatMediaKind::Audio
            },
            media,
        ),
        crate::types::MessageContent::Document { media, .. } => (ChatMediaKind::Document, media),
        _ => return None,
    };
    Some(ChatMedia {
        message: message.id.clone(),
        timestamp: message.timestamp,
        kind,
        size: media.size,
        here: media
            .path
            .as_deref()
            .is_some_and(|path| std::path::Path::new(path).exists()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use zapfast::model::{Content, Delivery, Message};

    fn message(id: &str, timestamp: i64) -> Message {
        Message {
            id: id.into(),
            chat: "chat@s.whatsapp.net".into(),
            sender: "chat@s.whatsapp.net".into(),
            sender_name: None,
            from_me: false,
            timestamp,
            history_order: None,
            content: Content::Text {
                text: format!("text of {id}"),
                preview: None,
            },
            status: Delivery::Read,
            delivered_at: None,
            read_at: None,
            quoted: None,
            reactions: Vec::new(),
            edited: false,
            mentions: Vec::new(),
            forwarded: false,
            thumbnail: None,
        }
    }

    fn reader_with(messages: &[Message]) -> ChatReader {
        let archive = Archive::in_memory().unwrap();
        archive
            .ensure_chat("chat@s.whatsapp.net", "Somebody")
            .unwrap();
        for message in messages {
            archive.insert_message(message, None).unwrap();
        }
        ChatReader::new(archive)
    }

    fn ids(page: &[MessageRecord]) -> Vec<&str> {
        page.iter().map(|message| message.id.as_str()).collect()
    }

    #[test]
    fn pages_walk_a_chat_back_to_its_start_without_gaps() {
        // Five messages, three of them in the same second: the boundary must
        // use the message, not just its time, or the ties are lost.
        let reader = reader_with(&[
            message("a", 100),
            message("b", 200),
            message("c", 200),
            message("d", 200),
            message("e", 300),
        ]);
        let chat = "chat@s.whatsapp.net";

        let newest = reader.page(chat.into(), None, 2).unwrap();
        assert_eq!(ids(&newest), ["d", "e"]);

        let middle = reader
            .page(
                chat.into(),
                Some(PageKey {
                    timestamp: newest[0].timestamp,
                    id: newest[0].id.clone(),
                }),
                2,
            )
            .unwrap();
        assert_eq!(ids(&middle), ["b", "c"]);

        let oldest = reader
            .page(
                chat.into(),
                Some(PageKey {
                    timestamp: middle[0].timestamp,
                    id: middle[0].id.clone(),
                }),
                2,
            )
            .unwrap();
        assert_eq!(ids(&oldest), ["a"]);

        let beyond = reader
            .page(
                chat.into(),
                Some(PageKey {
                    timestamp: oldest[0].timestamp,
                    id: oldest[0].id.clone(),
                }),
                2,
            )
            .unwrap();
        assert!(beyond.is_empty());
    }

    fn media(path: Option<&std::path::Path>, size: u64) -> zapfast::model::Media {
        zapfast::model::Media {
            mime: "application/octet-stream".into(),
            size,
            width: None,
            height: None,
            path: path.map(Into::into),
            state: Default::default(),
        }
    }

    fn with(id: &str, timestamp: i64, content: Content) -> Message {
        Message {
            content,
            ..message(id, timestamp)
        }
    }

    #[test]
    fn the_census_lists_attachments_newest_first_and_says_which_are_here() {
        let folder = std::env::temp_dir().join(format!("zapfast-census-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let present = folder.join("a.jpg");
        std::fs::write(&present, b"x").unwrap();
        let deleted = folder.join("gone.pdf");

        let reader = reader_with(&[
            with(
                "photo",
                100,
                Content::Image {
                    caption: None,
                    media: media(Some(&present), 10),
                },
            ),
            message("text", 150),
            with(
                "voice",
                200,
                Content::Audio {
                    media: media(None, 20),
                    seconds: Some(3),
                    voice_note: true,
                    waveform: Vec::new(),
                },
            ),
            with(
                "song",
                250,
                Content::Audio {
                    media: media(None, 21),
                    seconds: Some(180),
                    voice_note: false,
                    waveform: Vec::new(),
                },
            ),
            with(
                "report",
                300,
                Content::Document {
                    media: media(Some(&deleted), 30),
                    file_name: "report.pdf".into(),
                    caption: None,
                    pages: None,
                },
            ),
            with(
                "clip",
                400,
                Content::Video {
                    caption: None,
                    media: media(None, 40),
                    seconds: Some(9),
                    gif: false,
                    note: false,
                },
            ),
            with(
                "sticker",
                450,
                Content::Sticker {
                    media: media(None, 5),
                    animated: false,
                },
            ),
        ]);

        let census = reader.census("chat@s.whatsapp.net".into()).unwrap();
        assert_eq!(census.messages, 7);
        assert_eq!(census.oldest, Some(100));
        let listed: Vec<_> = census
            .media
            .iter()
            .map(|item| (item.message.as_str(), item.kind, item.size, item.here))
            .collect();
        assert_eq!(
            listed,
            [
                ("clip", ChatMediaKind::Video, 40, false),
                // The file is named in the archive but not on disk.
                ("report", ChatMediaKind::Document, 30, false),
                ("song", ChatMediaKind::Audio, 21, false),
                ("voice", ChatMediaKind::Voice, 20, false),
                ("photo", ChatMediaKind::Photo, 10, true),
            ],
            "stickers are left out, and text carries nothing"
        );
        std::fs::remove_dir_all(&folder).ok();
    }

    #[test]
    fn the_census_reads_a_chat_longer_than_one_page() {
        let total = CENSUS_PAGE * 2 + 37;
        let messages: Vec<_> = (0..total)
            .map(|index| {
                with(
                    &format!("m{index:05}"),
                    1000 + index as i64,
                    Content::Image {
                        caption: None,
                        media: media(None, 1),
                    },
                )
            })
            .collect();
        let reader = reader_with(&messages);
        let census = reader.census("chat@s.whatsapp.net".into()).unwrap();
        assert_eq!(census.messages as usize, total);
        assert_eq!(census.media.len(), total);
        assert_eq!(census.oldest, Some(1000));
        assert_eq!(census.media[0].message, format!("m{:05}", total - 1));
        assert_eq!(census.media[total - 1].message, "m00000");
    }

    #[test]
    fn the_census_of_an_empty_chat_is_empty() {
        let reader = reader_with(&[]);
        let census = reader.census("chat@s.whatsapp.net".into()).unwrap();
        assert_eq!(census.messages, 0);
        assert_eq!(census.oldest, None);
        assert!(census.media.is_empty());
    }

    #[test]
    fn another_chat_is_never_mixed_in() {
        let reader = reader_with(&[message("a", 100)]);
        let other = reader
            .page("other@s.whatsapp.net".into(), None, 10)
            .unwrap();
        assert!(other.is_empty());
    }
}
