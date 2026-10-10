//! The search inside one chat: words in any order, a sender, a kind of
//! message, and a span of time.
//!
//! Words are matched on a folded form of the text rather than with `LIKE`:
//! SQLite folds case for ASCII only, so `Привет` never found `привет`, and
//! Uzbek is written three ways. The fold lowercases, drops accents and the
//! apostrophe-like marks (`o'`, `oʻ`, `o‘` all become `o`), and reads Uzbek
//! Cyrillic as Uzbek Latin, so `salom`, `Salom` and `Салом` find each other.
//! Both sides go through the same fold, so the rules only have to agree with
//! themselves, not be a faithful transliteration.
//!
//! A word that starts with a letter matches the start of a word, so `the`
//! finds `theme` but not `smoother`, while Uzbek's suffixes still follow
//! (`arzon` finds `arzonroq`). Digits match anywhere: a part number is
//! searched for by any piece of it, `1132200` in `LJ4K18AQ1132200AB`.

use super::{
    Archive, Message, OptionalExtension, Result, SEARCH_COLUMNS, SEARCHED_TEXT, params,
    searched_message,
};

/// What a chat's search asks for. Everything given must hold.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChatSearch {
    pub chat: String,
    /// Echoed in the answer, so a late answer to an earlier search can be
    /// told apart.
    pub request: u64,
    /// Words, each to be found somewhere in the message, in any order.
    pub query: String,
    /// Unix seconds, inclusive.
    pub from: Option<i64>,
    /// Unix seconds, exclusive.
    pub until: Option<i64>,
    pub sender: Option<SearchSender>,
    pub kind: Option<SearchKind>,
    /// Matches returned whole, newest first; the rest come as ids only.
    pub limit: usize,
}

/// Whose messages a search keeps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SearchSender {
    /// Ours.
    Me,
    /// Someone else's, under any of the ids the archive filed them by: a
    /// phone number, and the privacy id it stood behind before the mapping
    /// was known.
    Person(Vec<String>),
}

/// The kinds of message a search can be kept to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SearchKind {
    Photos,
    /// Videos and round video messages, not GIFs.
    Videos,
    Gifs,
    Files,
    /// Messages with a web address in their text or caption.
    Links,
    Voice,
    /// Audio that is not a voice message.
    Music,
}

impl SearchKind {
    /// The condition on `messages.content` that keeps this kind.
    fn condition(self) -> &'static str {
        match self {
            Self::Photos => "json_extract(content, '$.kind') = 'image'",
            Self::Videos => {
                "json_extract(content, '$.kind') = 'video' AND NOT coalesce(json_extract(content, '$.gif'), 0)"
            }
            Self::Gifs => {
                "json_extract(content, '$.kind') = 'video' AND coalesce(json_extract(content, '$.gif'), 0)"
            }
            Self::Files => "json_extract(content, '$.kind') = 'document'",
            Self::Links => {
                "(json_extract(content, '$.preview') IS NOT NULL OR lower(
                    coalesce(json_extract(content, '$.text'), '') || char(10) ||
                    coalesce(json_extract(content, '$.caption'), '')
                ) GLOB '*http://*' OR lower(
                    coalesce(json_extract(content, '$.text'), '') || char(10) ||
                    coalesce(json_extract(content, '$.caption'), '')
                ) GLOB '*https://*' OR lower(
                    coalesce(json_extract(content, '$.text'), '') || char(10) ||
                    coalesce(json_extract(content, '$.caption'), '')
                ) GLOB '*www.*')"
            }
            Self::Voice => {
                "json_extract(content, '$.kind') = 'audio' AND coalesce(json_extract(content, '$.voice_note'), 0)"
            }
            Self::Music => {
                "json_extract(content, '$.kind') = 'audio' AND NOT coalesce(json_extract(content, '$.voice_note'), 0)"
            }
        }
    }
}

/// The answer to a [`ChatSearch`].
#[derive(Clone, Debug, PartialEq)]
pub struct ChatSearchHits {
    pub chat: String,
    pub request: u64,
    /// Every match's id, newest first, up to [`ID_LIMIT`].
    pub ids: Vec<String>,
    /// The newest matches whole, up to the search's `limit`.
    pub messages: Vec<Message>,
    /// More matched than `ids` carries.
    pub truncated: bool,
}

/// Ids an answer carries at most: enough to step through any real search,
/// few enough to cross to the interface in a moment.
pub const ID_LIMIT: usize = 10_000;

impl Archive {
    /// Searches one chat. With no words, every message the other
    /// conditions keep is a match, so a sender or a kind lists on its own.
    pub fn search_chat(&self, search: &ChatSearch) -> Result<ChatSearchHits> {
        let terms = query_terms(&search.query);
        let (sender_condition, people) = match &search.sender {
            None => ("1", None),
            Some(SearchSender::Me) => ("from_me = 1", None),
            Some(SearchSender::Person(ids)) => (
                "from_me = 0 AND sender IN (SELECT value FROM json_each(?4))",
                Some(serde_json::to_string(ids).unwrap_or_default()),
            ),
        };
        let kind_condition = search.kind.map_or("1", SearchKind::condition);
        // Concrete bounds, so SQLite walks the `(chat, timestamp)` index
        // over just the range.
        let sql = format!(
            "SELECT {SEARCH_COLUMNS}, {SEARCHED_TEXT}
             FROM messages
             WHERE chat = ?1 AND timestamp >= ?2 AND timestamp < ?3
             AND json_valid(content)
             AND ({sender_condition}) AND ({kind_condition})
             ORDER BY timestamp DESC, COALESCE(history_order, 9223372036854775807) DESC, rowid DESC"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let from = search.from.unwrap_or(i64::MIN);
        let until = search.until.unwrap_or(i64::MAX);
        let mut rows = match &people {
            Some(people) => statement.query(params![search.chat, from, until, people])?,
            None => statement.query(params![search.chat, from, until])?,
        };
        let text_column = SEARCH_COLUMNS.split(',').count();
        let mut hits = ChatSearchHits {
            chat: search.chat.clone(),
            request: search.request,
            ids: Vec::new(),
            messages: Vec::new(),
            truncated: false,
        };
        let mut folded = String::new();
        while let Some(row) = rows.next()? {
            if !terms.is_empty() {
                let text: String = row.get(text_column)?;
                folded.clear();
                fold_into(&text, &mut folded);
                if !terms.iter().all(|term| contains_term(&folded, term)) {
                    continue;
                }
            }
            if hits.ids.len() == ID_LIMIT {
                hits.truncated = true;
                break;
            }
            if hits.messages.len() < search.limit {
                let message = searched_message(row)?;
                hits.ids.push(message.id.clone());
                hits.messages.push(message);
            } else {
                hits.ids.push(row.get(1)?);
            }
        }
        Ok(hits)
    }

    /// The first message of each span `[starts[i], starts[i + 1])`, for a
    /// calendar that marks the days with messages and opens each at its
    /// first. One entry fewer than `starts`.
    pub fn first_messages(&self, chat: &str, starts: &[i64]) -> Result<Vec<Option<String>>> {
        let mut statement = self.connection.prepare(
            "SELECT id FROM messages
             WHERE chat = ?1 AND timestamp >= ?2 AND timestamp < ?3
             ORDER BY timestamp ASC, COALESCE(history_order, 9223372036854775807) ASC, rowid ASC
             LIMIT 1",
        )?;
        starts
            .windows(2)
            .map(|span| {
                statement
                    .query_row(params![chat, span[0], span[1]], |row| row.get(0))
                    .optional()
            })
            .collect()
    }
}

/// The query's words, folded; marks alone fold to nothing and are dropped.
pub fn query_terms(query: &str) -> Vec<String> {
    query
        .split_whitespace()
        .map(fold)
        .filter(|term| !term.is_empty())
        .collect()
}

/// Whether `text` holds every word of `query`, as the archive's search
/// decides it. A query with no words matches nothing here.
pub fn matches(text: &str, query: &str) -> bool {
    let terms = query_terms(query);
    let folded = fold(text);
    !terms.is_empty() && terms.iter().all(|term| contains_term(&folded, term))
}

/// Whether `term` stands in `folded` where a search counts it: anywhere for
/// a term that does not start with a letter, else not in the middle of a
/// run of letters.
fn contains_term(folded: &str, term: &str) -> bool {
    folded
        .match_indices(term)
        .any(|(at, _)| may_start(folded[..at].chars().next_back(), term))
}

/// A term may start after `previous` unless both are letters.
fn may_start(previous: Option<char>, term: &str) -> bool {
    let letter_term = term.chars().next().is_some_and(char::is_alphabetic);
    !letter_term || !previous.is_some_and(char::is_alphabetic)
}

/// Where the words of `query` stand in `text`, as UTF-16 `(start, length)`
/// spans in order, overlapping ones merged: what an interface marks.
pub fn match_ranges(text: &str, query: &str) -> Vec<(u32, u32)> {
    let terms: Vec<(String, Vec<char>)> = query_terms(query)
        .into_iter()
        .map(|term| {
            let chars = term.chars().collect();
            (term, chars)
        })
        .collect();
    if terms.is_empty() {
        return Vec::new();
    }
    // Each folded character, and the span of `text` it came from.
    let mut folded: Vec<char> = Vec::new();
    let mut origin: Vec<(u32, u32)> = Vec::new();
    fold_each(text, |piece, start, end| {
        for character in piece.chars() {
            folded.push(character);
            origin.push((start, end));
        }
    });
    let mut spans: Vec<(u32, u32)> = Vec::new();
    for (text_term, term) in &terms {
        let mut at = 0;
        while at + term.len() <= folded.len() {
            // Overlapping occurrences too: "aa" marks all of "aaa".
            if folded[at..at + term.len()] == term[..]
                && may_start(at.checked_sub(1).map(|before| folded[before]), text_term)
            {
                spans.push((origin[at].0, origin[at + term.len() - 1].1));
            }
            at += 1;
        }
    }
    spans.sort_unstable();
    let mut merged: Vec<(u32, u32)> = Vec::new();
    for (start, end) in spans {
        match merged.last_mut() {
            Some(last) if start <= last.1 => last.1 = last.1.max(end),
            _ => merged.push((start, end)),
        }
    }
    merged
        .into_iter()
        .map(|(start, end)| (start, end - start))
        .collect()
}

/// `text` as the search compares it.
pub fn fold(text: &str) -> String {
    let mut folded = String::with_capacity(text.len());
    fold_into(text, &mut folded);
    folded
}

fn fold_into(text: &str, folded: &mut String) {
    if text.is_ascii() && !text.bytes().any(|byte| byte == b'\'' || byte == b'`') {
        folded.extend(text.chars().map(|c| c.to_ascii_lowercase()));
        return;
    }
    fold_each(text, |piece, _, _| folded.push_str(piece));
}

/// Hands over the folded form of each character of `text` with the UTF-16
/// span it came from. A character may fold to nothing or to several.
fn fold_each(text: &str, mut emit: impl FnMut(&str, u32, u32)) {
    use icu_normalizer::DecomposingNormalizerBorrowed;
    use icu_properties::{CodePointMapData, props::GeneralCategory};

    let mut offset = 0u32;
    let mut previous: Option<char> = None;
    let mut buffer = String::new();
    for character in text.chars() {
        let start = offset;
        offset += character.len_utf16() as u32;
        buffer.clear();
        for lower in character.to_lowercase() {
            if let Some(latin) = uzbek_latin(lower, previous) {
                buffer.push_str(latin);
            } else if is_apostrophe(lower) {
                // Nothing: `o'`, `oʻ` and `o` meet.
            } else if lower.is_ascii() {
                buffer.push(lower);
            } else {
                buffer.extend(
                    DecomposingNormalizerBorrowed::new_nfd()
                        .normalize_iter(std::iter::once(lower))
                        .filter(|c| {
                            CodePointMapData::<GeneralCategory>::new().get(*c)
                                != GeneralCategory::NonspacingMark
                        }),
                );
            }
        }
        previous = Some(character);
        if !buffer.is_empty() {
            emit(&buffer, start, offset);
        }
    }
}

/// The marks people type for Uzbek's `ʻ` and `ʼ`, and for the Cyrillic hard
/// sign's sound.
fn is_apostrophe(character: char) -> bool {
    matches!(
        character,
        '\'' | '`'
            | '\u{00B4}'
            | '\u{02B9}'
            | '\u{02BB}'
            | '\u{02BC}'
            | '\u{2018}'
            | '\u{2019}'
            | '\u{2032}'
    )
}

/// A lowercase Cyrillic letter in Uzbek Latin, without its apostrophes.
/// `е` is `ye` at the start of a word and after a vowel, as Uzbek writes it.
fn uzbek_latin(character: char, previous: Option<char>) -> Option<&'static str> {
    Some(match character {
        'а' => "a",
        'б' => "b",
        'в' => "v",
        'г' => "g",
        'д' => "d",
        'е' => {
            let after_vowel = previous
                .and_then(|c| c.to_lowercase().next())
                .is_some_and(|c| "аеёиоуэюяўыъь".contains(c));
            if previous.is_none_or(|c| !c.is_alphabetic()) || after_vowel {
                "ye"
            } else {
                "e"
            }
        }
        'ё' => "yo",
        'ж' => "j",
        'з' => "z",
        'и' | 'ы' | 'і' => "i",
        'й' => "y",
        'к' => "k",
        'л' => "l",
        'м' => "m",
        'н' => "n",
        'о' | 'ў' => "o",
        'п' => "p",
        'р' => "r",
        'с' => "s",
        'т' => "t",
        'у' => "u",
        'ф' => "f",
        'х' => "x",
        'ц' => "ts",
        'ч' => "ch",
        'ш' | 'щ' => "sh",
        'ъ' | 'ь' => "",
        'э' => "e",
        'ю' => "yu",
        'я' => "ya",
        'қ' => "q",
        'ғ' => "g",
        'ҳ' => "h",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archive::tests::message;
    use crate::model::{Content, Media};

    fn media() -> Media {
        Media {
            mime: "application/octet-stream".into(),
            size: 0,
            width: None,
            height: None,
            path: None,
            state: Default::default(),
        }
    }

    #[test]
    fn case_marks_and_scripts_fold_together() {
        assert_eq!(fold("Salom"), "salom");
        assert_eq!(fold("Салом"), "salom");
        assert_eq!(fold("ПРИВЕТ"), fold("привет"));
        // Uzbek's ʻ is typed four ways; all of them, and none, meet.
        for spelling in [
            "oʻzbek",
            "o'zbek",
            "o‘zbek",
            "o’zbek",
            "ozbek",
            "ўзбек",
            "Ўзбек",
        ] {
            assert_eq!(fold(spelling), "ozbek", "{spelling}");
        }
        assert_eq!(fold("gʻalaba"), fold("ғалаба"));
        assert_eq!(fold("yetti"), fold("етти"), "е starts a word as ye");
        assert_eq!(fold("oyela"), fold("оела"), "and follows a vowel as ye");
        assert_eq!(fold("telefon"), fold("телефон"), "elsewhere it is e");
        assert_eq!(fold("choʻqqi"), fold("чўққи"));
        assert_eq!(fold("Café"), "cafe");
        assert_eq!(fold("ma'no"), fold("маъно"));
    }

    #[test]
    fn every_word_must_match_in_any_order() {
        assert!(matches("Oem ni arzonroq bermasmikan", "arzon oem"));
        assert!(!matches("Oem ni arzonroq bermasmikan", "arzon qimmat"));
        assert!(matches("Ўзбекистон", "o'zbek"));
        // Words start words; numbers are found inside part numbers.
        assert!(!matches("Scrolling feels smoother", "the"));
        assert!(matches("the theme", "theme"));
        assert!(matches("LJ4K18AQ1132200AB", "1132200"));
        assert!(matches("LJ4K18AQ1132200AB", "aq11"));
        assert!(
            !matches("LJ4K18AQ1132200AB", "j4k"),
            "j follows the letter l"
        );
        assert!(matches("Narxi: 550$", "550"));
        assert!(!matches("anything", "   "));
        assert!(query_terms("  ' ").is_empty(), "a mark alone asks nothing");
    }

    #[test]
    fn ranges_point_into_the_original_text() {
        // "Салом" is five UTF-16 units, as is its fold.
        assert_eq!(match_ranges("Ha, Салом!", "salom"), vec![(4, 5)]);
        // ч folds to two letters, still one character of the original.
        assert_eq!(match_ranges("чой", "ch"), vec![(0, 1)]);
        // The apostrophe sits inside the match.
        assert_eq!(match_ranges("oʻzbek tili", "ozbek"), vec![(0, 6)]);
        // Every occurrence at a word's start, in order; numbers anywhere,
        // overlaps merged.
        assert_eq!(match_ranges("abab ab", "ab"), vec![(0, 2), (5, 2)]);
        assert_eq!(match_ranges("12 1212", "12"), vec![(0, 2), (3, 4)]);
        assert_eq!(match_ranges("smoother the", "the"), vec![(9, 3)]);
        // Characters outside the BMP count as two units.
        assert_eq!(match_ranges("😀 tea", "tea"), vec![(3, 3)]);
        assert!(match_ranges("tea", "").is_empty());
    }

    fn archive_with(chat: &str, messages: &[Message]) -> Archive {
        let archive = Archive::in_memory().expect("opens");
        archive.ensure_chat(chat, "Group").expect("chat");
        for message in messages {
            archive.insert_message(message, None).expect("insert");
        }
        archive
    }

    fn search(chat: &str, query: &str) -> ChatSearch {
        ChatSearch {
            chat: chat.into(),
            request: 7,
            query: query.into(),
            limit: 50,
            ..ChatSearch::default()
        }
    }

    #[test]
    fn a_chat_search_folds_and_keeps_to_its_chat() {
        let chat = "1-2@g.us";
        let text = |id: &str, at: i64, body: &str| {
            let mut message = message(chat, id, at, false);
            message.content = Content::text(body);
            message
        };
        let mut elsewhere = message("3@s.whatsapp.net", "x", 50, false);
        elsewhere.content = Content::text("Салом");
        let archive = archive_with(
            chat,
            &[
                text("m1", 10, "Салом, дўстим"),
                text("m2", 20, "nothing"),
                text("m3", 30, "salom do'stim"),
            ],
        );
        archive.insert_message(&elsewhere, None).expect("insert");
        let hits = archive.search_chat(&search(chat, "SALOM")).expect("search");
        assert_eq!(hits.request, 7, "the request is echoed");
        assert_eq!(hits.ids, ["m3", "m1"], "newest first, both scripts");
        assert_eq!(hits.messages.len(), 2);
        assert!(!hits.truncated);
        let hits = archive
            .search_chat(&search(chat, "dostim salom"))
            .expect("search");
        assert_eq!(hits.ids, ["m3", "m1"]);
        // Past the limit, ids only.
        let limited = ChatSearch {
            limit: 1,
            ..search(chat, "salom")
        };
        let hits = archive.search_chat(&limited).expect("search");
        assert_eq!(hits.ids, ["m3", "m1"]);
        assert_eq!(hits.messages.len(), 1);
        assert_eq!(hits.messages[0].id, "m3");
        // A time span.
        let span = ChatSearch {
            from: Some(5),
            until: Some(30),
            ..search(chat, "salom")
        };
        assert_eq!(archive.search_chat(&span).expect("search").ids, ["m1"]);
    }

    #[test]
    fn a_sender_and_a_kind_list_on_their_own() {
        let chat = "1-2@g.us";
        let farhod = "998901@s.whatsapp.net";
        let hidden = "777@lid";
        let mut photo = message(chat, "p", 10, false);
        photo.sender = farhod.into();
        photo.content = Content::Image {
            caption: Some("Narxi".into()),
            media: media(),
        };
        let mut voice = message(chat, "v", 20, false);
        voice.sender = hidden.into();
        voice.content = Content::Audio {
            media: media(),
            seconds: Some(3),
            voice_note: true,
            waveform: Vec::new(),
        };
        let mut link = message(chat, "l", 30, true);
        link.content = Content::text("Mana: https://example.com/narx");
        let mut gif = message(chat, "g", 40, false);
        gif.content = Content::Video {
            caption: None,
            media: media(),
            seconds: Some(2),
            gif: true,
            note: false,
        };
        let archive = archive_with(chat, &[photo, voice, link, gif]);
        let with = |sender: Option<SearchSender>, kind: Option<SearchKind>, query: &str| {
            archive
                .search_chat(&ChatSearch {
                    sender,
                    kind,
                    ..search(chat, query)
                })
                .expect("search")
                .ids
        };
        let farhod_anywhere = SearchSender::Person(vec![farhod.into(), hidden.into()]);
        assert_eq!(with(Some(farhod_anywhere.clone()), None, ""), ["v", "p"]);
        assert_eq!(with(Some(farhod_anywhere), None, "narx"), ["p"]);
        assert_eq!(with(Some(SearchSender::Me), None, ""), ["l"]);
        assert_eq!(with(None, Some(SearchKind::Photos), ""), ["p"]);
        assert_eq!(with(None, Some(SearchKind::Voice), ""), ["v"]);
        assert_eq!(
            with(None, Some(SearchKind::Music), ""),
            Vec::<String>::new()
        );
        assert_eq!(with(None, Some(SearchKind::Links), ""), ["l"]);
        assert_eq!(with(None, Some(SearchKind::Gifs), ""), ["g"]);
        assert_eq!(
            with(None, Some(SearchKind::Videos), ""),
            Vec::<String>::new()
        );
        assert_eq!(with(None, None, "narx"), ["l", "p"], "captions count");
    }

    #[test]
    fn first_messages_mark_each_span() {
        let chat = "1-2@g.us";
        let archive = archive_with(
            chat,
            &[
                message(chat, "a", 12, false),
                message(chat, "b", 11, false),
                message(chat, "c", 35, false),
            ],
        );
        assert_eq!(
            archive
                .first_messages(chat, &[0, 10, 20, 30, 40])
                .expect("days"),
            [None, Some("b".to_owned()), None, Some("c".to_owned())]
        );
        assert!(archive.first_messages(chat, &[0]).expect("days").is_empty());
    }
}
