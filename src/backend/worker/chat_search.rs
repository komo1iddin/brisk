//! The search inside one chat (`archive::chat_search`) and the days its
//! calendar marks.
//!
//! A person's messages may be filed under their phone number or under the
//! privacy id (`@lid`) they arrived behind before the mapping was known, so a
//! search for one sender asks for every id the archive could have used.

use super::*;
use crate::archive::{ChatSearch, ChatSearchHits, SearchSender};

impl Worker {
    /// Answers every search, a failed one with no matches, so the interface
    /// never waits for an answer that is not coming.
    pub(super) fn search_chat(&mut self, mut search: ChatSearch) {
        if let Some(SearchSender::Person(ids)) = &mut search.sender {
            *ids = self.sender_aliases(ids);
        }
        match self.archive.search_chat(&search) {
            Ok(mut hits) => {
                for message in &mut hits.messages {
                    self.polish(message);
                }
                self.emit(Event::ChatSearchHits(hits));
            }
            Err(error) => {
                self.emit(Event::ChatSearchHits(ChatSearchHits {
                    chat: search.chat,
                    request: search.request,
                    ids: Vec::new(),
                    messages: Vec::new(),
                    truncated: false,
                }));
                self.emit(Event::Error(format!("Could not search: {error}")));
            }
        }
    }

    pub(super) fn chat_days(&mut self, chat: ChatId, starts: Vec<i64>) {
        match self.archive.first_messages(&chat, &starts) {
            Ok(first) => self.emit(Event::ChatDays {
                chat,
                starts,
                first,
            }),
            Err(error) => self.emit(Event::Error(format!(
                "Could not read the calendar: {error}"
            ))),
        }
    }

    /// The ids as given, their canonical form, and the privacy ids known to
    /// stand for the same phone numbers.
    fn sender_aliases(&self, ids: &[String]) -> Vec<String> {
        let mut all: Vec<String> = Vec::new();
        let mut add = |id: String| {
            if !all.contains(&id) {
                all.push(id);
            }
        };
        for id in ids {
            add(id.clone());
            let canonical = self.canonical_str(id);
            if let Some(phone) = canonical.strip_suffix("@s.whatsapp.net") {
                for (lid, pn) in &self.lid_to_pn {
                    if pn == phone {
                        add(format!("{lid}@lid"));
                    }
                }
            }
            add(canonical);
        }
        all
    }
}
