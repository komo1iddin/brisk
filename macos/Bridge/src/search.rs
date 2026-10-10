//! The search inside a chat: its filters as Swift names them, and the
//! archive's own matching, so the words a bubble marks are exactly the ones
//! the archive matched.

use zapfast::archive::{SearchKind, SearchSender};

/// Whose messages a chat's search keeps.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SearchSenderInfo {
    Me,
    /// A person by any id Swift knows them by; the backend adds the rest.
    Person {
        id: String,
    },
}

impl From<SearchSenderInfo> for SearchSender {
    fn from(sender: SearchSenderInfo) -> Self {
        match sender {
            SearchSenderInfo::Me => Self::Me,
            SearchSenderInfo::Person { id } => Self::Person(vec![id]),
        }
    }
}

/// The kinds of message a chat's search can be kept to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SearchKindInfo {
    Photos,
    Videos,
    Gifs,
    Files,
    Links,
    Voice,
    Music,
}

impl From<SearchKindInfo> for SearchKind {
    fn from(kind: SearchKindInfo) -> Self {
        match kind {
            SearchKindInfo::Photos => Self::Photos,
            SearchKindInfo::Videos => Self::Videos,
            SearchKindInfo::Gifs => Self::Gifs,
            SearchKindInfo::Files => Self::Files,
            SearchKindInfo::Links => Self::Links,
            SearchKindInfo::Voice => Self::Voice,
            SearchKindInfo::Music => Self::Music,
        }
    }
}

/// A span of text in UTF-16 units, as `NSRange` counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TextSpan {
    pub start: u32,
    pub length: u32,
}

/// Where the words of `query` stand in `text`, as the chat's search
/// matches them: any case, any of Uzbek's apostrophes, Latin or Cyrillic.
#[uniffi::export]
pub fn search_match_spans(text: String, query: String) -> Vec<TextSpan> {
    zapfast::archive::chat_search::match_ranges(&text, &query)
        .into_iter()
        .map(|(start, length)| TextSpan { start, length })
        .collect()
}

/// Whether `text` holds every word of `query`, as the chat's search decides.
#[uniffi::export]
pub fn search_matches(text: String, query: String) -> bool {
    zapfast::archive::chat_search::matches(&text, &query)
}
