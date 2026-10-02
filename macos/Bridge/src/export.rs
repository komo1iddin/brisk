//! Reading a whole chat out of the archive, for "Export Chat".
//!
//! The worker owns the live archive and hands the interface only what it is
//! showing. An export needs every message, and must not disturb the open
//! timeline, so it reads through a connection of its own. SQLite lets a WAL
//! database be read while the worker writes to it.
//!
//! This only reads. Nothing here decides what an export looks like: Swift
//! formats the messages, so dates and wording follow the reader's language.

use std::sync::Mutex;

use zapfast::archive::Archive;

use crate::client::BridgeError;
use crate::types::{MessageRecord, PageKey};

/// One open connection to the archive, held for the length of an export.
#[derive(uniffi::Object)]
pub struct ChatReader {
    archive: Mutex<Archive>,
}

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

    #[test]
    fn another_chat_is_never_mixed_in() {
        let reader = reader_with(&[message("a", 100)]);
        let other = reader.page("other@s.whatsapp.net".into(), None, 10).unwrap();
        assert!(other.is_empty());
    }
}
