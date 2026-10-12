//! Bounded, bidirectional archive reads. All boundaries use the archive's
//! timestamp, phone order and rowid, including messages in the same second.
use super::{Archive, PAGE, Result};
use crate::model::Message;
use rusqlite::params;

#[derive(Clone, Debug, PartialEq)]
pub enum WindowQuery {
    Newest,
    Before(String),
    After(String),
    Around(String),
}

pub struct MessageWindow {
    pub messages: Vec<Message>,
    pub has_older: bool,
    pub has_newer: bool,
}

impl Archive {
    fn messages_after(&self, chat: &str, id: &str, limit: usize) -> Result<Vec<Message>> {
        let mut statement = self.connection.prepare(
            "SELECT id FROM messages WHERE chat = ?1 AND
             (timestamp, COALESCE(history_order, 9223372036854775807), rowid) >
             (SELECT timestamp, COALESCE(history_order, 9223372036854775807), rowid
              FROM messages WHERE chat = ?1 AND id = ?2)
             ORDER BY timestamp, COALESCE(history_order, 9223372036854775807), rowid LIMIT ?3",
        )?;
        let ids = statement.query_map(params![chat, id, limit as i64], |row| {
            row.get::<_, String>(0)
        })?;
        let mut messages = Vec::with_capacity(limit);
        for id in ids {
            if let Some(message) = self.message(chat, &id?)? {
                messages.push(message);
            }
        }
        Ok(messages)
    }

    /// Orders an explicit selection without materializing its message bodies.
    pub fn selected_message_ids(&self, chat: &str, ids: &[String]) -> Result<Vec<String>> {
        let mut statement = self.connection.prepare(
            "SELECT id FROM messages WHERE chat = ?1 AND id IN (SELECT value FROM json_each(?2))
             ORDER BY timestamp, COALESCE(history_order, 9223372036854775807), rowid",
        )?;
        let encoded = serde_json::to_string(ids).expect("strings serialize");
        statement
            .query_map(params![chat, encoded], |row| row.get(0))?
            .collect()
    }

    /// None means the requested boundary was removed or was never archived.
    /// An around read includes the target itself and at most PAGE on each side.
    pub fn message_window(&self, chat: &str, query: &WindowQuery) -> Result<Option<MessageWindow>> {
        let mut messages = match query {
            WindowQuery::Newest => self.messages(chat, None, PAGE)?,
            WindowQuery::Before(id) | WindowQuery::Around(id) => {
                let Some(target) = self.message(chat, id)? else {
                    return Ok(None);
                };
                let mut rows = self.messages(chat, Some((target.timestamp, id)), PAGE)?;
                if matches!(query, WindowQuery::Around(_)) {
                    rows.push(target);
                    rows.extend(self.messages_after(chat, id, PAGE)?);
                }
                rows
            }
            WindowQuery::After(id) => {
                if self.message(chat, id)?.is_none() {
                    return Ok(None);
                }
                self.messages_after(chat, id, PAGE)?
            }
        };
        // An empty edge answer still describes the boundary correctly.
        let boundary = match query {
            WindowQuery::Before(id) | WindowQuery::After(id) => self.message(chat, id)?,
            _ => None,
        };
        let first = messages.first().or(boundary.as_ref());
        let last = messages.last().or(boundary.as_ref());
        let has_older = if let Some(first) = first {
            !self
                .messages(chat, Some((first.timestamp, &first.id)), 1)?
                .is_empty()
        } else {
            false
        };
        let has_newer = if let Some(last) = last {
            !self.messages_after(chat, &last.id, 1)?.is_empty()
        } else {
            false
        };
        Ok(Some(MessageWindow {
            messages: std::mem::take(&mut messages),
            has_older,
            has_newer,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archive::tests::message;

    fn fixture() -> Archive {
        let archive = Archive::in_memory().unwrap();
        archive.ensure_chat("fixture", "Synthetic").unwrap();
        // Equal timestamps, reverse insertion order, explicit phone order.
        for i in (0..200).rev() {
            let mut row = message("fixture", &format!("m{i}"), 100, false);
            row.history_order = Some(i);
            archive.insert_message(&row, None).unwrap();
        }
        archive
    }

    #[test]
    fn both_edges_walk_equal_timestamps_without_gaps() {
        let archive = fixture();
        let newest = archive
            .message_window("fixture", &WindowQuery::Newest)
            .unwrap()
            .unwrap();
        assert_eq!(newest.messages.first().unwrap().id, "m140");
        assert!(newest.has_older);
        assert!(!newest.has_newer);
        let before = archive
            .message_window("fixture", &WindowQuery::Before("m140".into()))
            .unwrap()
            .unwrap();
        assert_eq!(before.messages.first().unwrap().id, "m80");
        assert_eq!(before.messages.last().unwrap().id, "m139");
        let after = archive
            .message_window("fixture", &WindowQuery::After("m79".into()))
            .unwrap()
            .unwrap();
        assert_eq!(
            after.messages.iter().map(|m| &m.id).collect::<Vec<_>>(),
            before.messages.iter().map(|m| &m.id).collect::<Vec<_>>()
        );
        assert!(after.has_older && after.has_newer);
    }

    #[test]
    fn around_includes_target_and_bounds_both_sides() {
        let archive = fixture();
        let middle = archive
            .message_window("fixture", &WindowQuery::Around("m100".into()))
            .unwrap()
            .unwrap();
        assert_eq!(middle.messages.len(), PAGE * 2 + 1);
        assert_eq!(middle.messages.first().unwrap().id, "m40");
        assert_eq!(middle.messages[PAGE].id, "m100");
        assert_eq!(middle.messages.last().unwrap().id, "m160");
        assert!(middle.has_older && middle.has_newer);
        let first = archive
            .message_window("fixture", &WindowQuery::Around("m0".into()))
            .unwrap()
            .unwrap();
        assert!(!first.has_older && first.has_newer);
        let end = archive
            .message_window("fixture", &WindowQuery::After("m199".into()))
            .unwrap()
            .unwrap();
        assert!(end.messages.is_empty() && end.has_older && !end.has_newer);
    }

    #[test]
    fn missing_boundary_and_other_chat_do_not_silently_jump() {
        let archive = fixture();
        for query in [
            WindowQuery::Before("absent".into()),
            WindowQuery::After("absent".into()),
            WindowQuery::Around("absent".into()),
        ] {
            assert!(archive.message_window("fixture", &query).unwrap().is_none());
        }
        assert!(
            archive
                .message_window("other", &WindowQuery::Around("m100".into()))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn explicit_selection_orders_ids_without_loading_bodies() {
        let archive = fixture();
        assert_eq!(
            archive
                .selected_message_ids(
                    "fixture",
                    &[
                        "m150".into(),
                        "missing".into(),
                        "m2".into(),
                        "m1".into(),
                        "m2".into()
                    ]
                )
                .unwrap(),
            ["m1", "m2", "m150"]
        );
        assert!(
            archive
                .selected_message_ids("other", &["m1".into()])
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn rowid_orders_messages_without_phone_order() {
        let archive = Archive::in_memory().unwrap();
        archive.ensure_chat("fixture", "Synthetic").unwrap();
        for id in ["z", "b", "a"] {
            archive
                .insert_message(&message("fixture", id, 100, false), None)
                .unwrap();
        }
        let after = archive
            .message_window("fixture", &WindowQuery::After("z".into()))
            .unwrap()
            .unwrap();
        assert_eq!(
            after
                .messages
                .iter()
                .map(|m| m.id.as_str())
                .collect::<Vec<_>>(),
            ["b", "a"]
        );
    }
}
