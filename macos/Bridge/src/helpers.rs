//! Pure upstream helpers, exported so Swift behaves exactly like upstream
//! instead of keeping its own copy of the rules.

use std::collections::HashMap;
use std::path::PathBuf;

use crate::client::BridgeError;
use crate::types::{PollDraftInfo, StickerLibrary, count, path_string};

/// Accent- and case-insensitive key for matching search text.
#[uniffi::export]
pub fn search_key(text: String) -> String {
    zapfast::util::search_key(&text)
}

/// The formatted phone number of a `<digits>@s.whatsapp.net` id.
#[uniffi::export]
pub fn phone_of(id: String) -> Option<String> {
    zapfast::model::phone_of(&id).map(zapfast::util::phone)
}

/// Sample rate of `decode_voice`'s output.
#[uniffi::export]
pub fn voice_sample_rate() -> u32 {
    zapfast::voice::RATE
}

/// Mono samples at `voice_sample_rate()` from a WhatsApp voice message
/// (Opus in OGG, which AVFoundation does not open). Blocking: call it off
/// the main thread.
#[uniffi::export]
pub fn decode_voice(path: String) -> Result<Vec<f32>, BridgeError> {
    let bytes = std::fs::read(&path).map_err(|error| BridgeError::Media {
        message: error.to_string(),
    })?;
    zapfast::voice::decode(&bytes).map_err(|message| BridgeError::Media { message })
}

/// Why a poll cannot be sent yet, in upstream's words, or `None` when it
/// can (upstream's `PollDraft::validated`).
#[uniffi::export]
pub fn poll_draft_problem(draft: PollDraftInfo) -> Option<String> {
    zapfast::model::PollDraft::from(draft)
        .validated()
        .err()
        .map(str::to_owned)
}

/// Upstream's label limits: how many labels, and how long a name.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LabelRules {
    pub limit: u32,
    pub name_limit: u32,
    /// The colours offered, `#rrggbb`; the first is the default.
    pub colors: Vec<String>,
}

#[uniffi::export]
pub fn label_rules() -> LabelRules {
    LabelRules {
        limit: count(zapfast::archive::LABEL_LIMIT),
        name_limit: count(zapfast::archive::NAME_LIMIT),
        colors: zapfast::ui::labels::PRESET_COLORS
            .iter()
            .map(|color| color.to_string())
            .collect(),
    }
}

/// Stickers matching `query` (upstream's `sticker_search::search`): by
/// emoji, by words naming an emoji, and by pack name; favorites and recent
/// first, each once.
#[uniffi::export]
pub fn search_stickers(library: StickerLibrary, query: String) -> Vec<String> {
    let StickerLibrary {
        favorites,
        packs,
        recent,
        received,
        emojis,
    } = library;
    let paths = |list: Vec<String>| list.into_iter().map(PathBuf::from).collect::<Vec<_>>();
    let packs: Vec<zapfast::model::StickerPack> = packs.into_iter().map(Into::into).collect();
    let emojis: HashMap<PathBuf, Vec<String>> = emojis
        .into_iter()
        .map(|entry| (PathBuf::from(entry.path), entry.emojis))
        .collect();
    let (favorites, recent, received) = (paths(favorites), paths(recent), paths(received));
    let found = zapfast::sticker_search::search(
        &zapfast::sticker_search::Library {
            recent: &recent,
            favorites: &favorites,
            packs: &packs,
            received: &received,
            emojis: &emojis,
        },
        &query,
    );
    found.into_iter().map(path_string).collect()
}

/// The GIPHY key to search with: ours from Settings, else one built into
/// upstream from `ZAPFAST_GIPHY_KEY`, else none (upstream's
/// `effective_giphy_key`).
#[uniffi::export]
pub fn giphy_key(own: String) -> Option<String> {
    zapfast::settings::Settings {
        giphy_key: own,
        ..Default::default()
    }
    .effective_giphy_key()
}

/// The code of a WhatsApp group invite link, such as
/// `https://chat.whatsapp.com/AbCd…`, or `None` for any other URL
/// (upstream's `safety::group_invite_code`).
#[uniffi::export]
pub fn group_invite_code(url: String) -> Option<String> {
    zapfast::safety::group_invite_code(&url)
}

/// One of WhatsApp's wallpaper colours, as upstream offers them.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WallpaperColorInfo {
    /// English name, as upstream labels it.
    pub name: String,
    /// `#rrggbb`.
    pub hex: String,
}

/// WhatsApp's wallpaper colours for light or dark appearance, in the
/// picker's order (upstream's `WallpaperColor::LIGHT` / `DARK`, without
/// its "Theme" entry, which follows upstream's own palette).
#[uniffi::export]
pub fn wallpaper_colors(dark: bool) -> Vec<WallpaperColorInfo> {
    zapfast::settings::WallpaperColor::choices(dark)
        .iter()
        .filter_map(|color| {
            let [r, g, b] = color.rgb()?;
            Some(WallpaperColorInfo {
                name: color.label().to_owned(),
                hex: format!("#{r:02x}{g:02x}{b:02x}"),
            })
        })
        .collect()
}

/// The doodles' ink over a wallpaper colour (upstream's `doodle_ink`):
/// dark or light, faint enough to stay behind the messages. `#rrggbbaa`.
#[uniffi::export]
pub fn doodle_ink(background_hex: String) -> String {
    let digits = background_hex.trim_start_matches('#');
    let value = u32::from_str_radix(digits, 16).unwrap_or(0xefeae2);
    let [_, r, g, b] = value.to_be_bytes();
    let ink = zapfast::wallpaper::doodle_ink(egui::Color32::from_rgb(r, g, b));
    let [r, g, b, a] = ink.to_srgba_unmultiplied();
    format!("#{r:02x}{g:02x}{b:02x}{a:02x}")
}

/// Upstream's shortest app-lock password, in characters.
/// One `:shortcode` completion: the emoji, its `:code:`, and its name.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EmojiSuggestionInfo {
    pub emoji: String,
    pub shortcode: String,
    pub name: String,
}

/// Upstream's `emoji_candidates` (`src/ui/conversation.rs`, private there,
/// so its ranking is repeated here over the same `emojis` data): six
/// completions for `:query`, the recently used ones first for an empty
/// query, otherwise exact shortcodes, then shortcode prefixes, names, and
/// substrings.
#[uniffi::export]
pub fn emoji_suggestions(query: String, recent: Vec<String>) -> Vec<EmojiSuggestionInfo> {
    const LIMIT: usize = 6;
    let query = query.to_lowercase();
    let mut seen = std::collections::HashSet::new();
    if query.is_empty() {
        return recent
            .iter()
            .filter_map(|emoji| emojis::get(emoji))
            .chain(emojis::iter())
            .filter(|emoji| seen.insert(emoji.as_str()))
            .take(LIMIT)
            .map(emoji_suggestion)
            .collect();
    }
    let mut found: Vec<_> = emojis::iter()
        .enumerate()
        .filter_map(|(order, emoji)| {
            emoji_match_score(emoji, &query).map(|score| (score, order, emoji))
        })
        .collect();
    found.sort_by_key(|(score, order, _)| (*score, *order));
    found
        .into_iter()
        .filter(|(_, _, emoji)| seen.insert(emoji.as_str()))
        .take(LIMIT)
        .map(|(_, _, emoji)| emoji_suggestion(emoji))
        .collect()
}

fn emoji_match_score(emoji: &emojis::Emoji, query: &str) -> Option<u8> {
    let name = emoji.name();
    let shortcodes = emoji.shortcodes();
    if shortcodes.clone().any(|code| code == query) {
        Some(0)
    } else if shortcodes.clone().any(|code| code.starts_with(query)) {
        Some(1)
    } else if name == query {
        Some(2)
    } else if name.starts_with(query)
        || name
            .split([' ', '-', '_'])
            .any(|word| word.starts_with(query))
    {
        Some(3)
    } else if shortcodes.clone().any(|code| code.contains(query)) {
        Some(4)
    } else if name.contains(query) {
        Some(5)
    } else {
        None
    }
}

fn emoji_suggestion(emoji: &'static emojis::Emoji) -> EmojiSuggestionInfo {
    let shortcode = emoji
        .shortcode()
        .map_or_else(|| emoji.name().replace([' ', '-'], "_"), str::to_owned);
    EmojiSuggestionInfo {
        emoji: emoji.as_str().to_owned(),
        shortcode: format!(":{shortcode}:"),
        name: emoji.name().to_owned(),
    }
}

/// One category of the emoji picker: its tab symbol, name, and emoji.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EmojiGroupInfo {
    pub symbol: String,
    pub name: String,
    pub emoji: Vec<String>,
}

/// Upstream's picker categories (`CATEGORIES` and `group_name` in
/// `src/ui/picker.rs`), over the same `emojis` data.
#[uniffi::export]
pub fn emoji_groups() -> Vec<EmojiGroupInfo> {
    emojis::Group::iter()
        .map(|group| {
            let (symbol, name) = match group {
                emojis::Group::SmileysAndEmotion => ("😀", "Smileys & Emotion"),
                emojis::Group::PeopleAndBody => ("👋", "People & Body"),
                emojis::Group::AnimalsAndNature => ("🐻", "Animals & Nature"),
                emojis::Group::FoodAndDrink => ("🍔", "Food & Drink"),
                emojis::Group::TravelAndPlaces => ("🚗", "Travel & Places"),
                emojis::Group::Activities => ("⚽", "Activities"),
                emojis::Group::Objects => ("💡", "Objects"),
                emojis::Group::Symbols => ("🔣", "Symbols"),
                emojis::Group::Flags => ("🏁", "Flags"),
            };
            EmojiGroupInfo {
                symbol: symbol.into(),
                name: name.into(),
                emoji: group
                    .emojis()
                    .map(|emoji| emoji.as_str().to_owned())
                    .collect(),
            }
        })
        .collect()
}

/// Upstream's picker search (`rows_for`): every emoji whose name or a
/// shortcode contains the query, in the data's order.
#[uniffi::export]
pub fn emoji_search(query: String) -> Vec<String> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }
    emojis::iter()
        .filter(|emoji| {
            emoji.name().to_lowercase().contains(&query)
                || emoji
                    .shortcodes()
                    .any(|code| code.to_lowercase().contains(&query))
        })
        .map(|emoji| emoji.as_str().to_owned())
        .collect()
}

/// Upstream's `quick_reactions` (`src/ui/conversation.rs`): the most used
/// reactions, filled up to six from its defaults, and our current one
/// when it is not among them.
#[uniffi::export]
pub fn quick_reactions(preferred: Vec<String>, mine: Option<String>) -> Vec<String> {
    const DEFAULTS: [&str; 6] = ["👍", "❤️", "😂", "😮", "😢", "🙏"];
    let mut list: Vec<String> = Vec::new();
    for emoji in preferred.iter().map(String::as_str).chain(DEFAULTS) {
        if emojis::get(emoji).is_some() && !list.iter().any(|known| known == emoji) {
            list.push(emoji.to_owned());
        }
        if list.len() == DEFAULTS.len() {
            break;
        }
    }
    if let Some(mine) = mine
        && !list.contains(&mine)
    {
        list.push(mine);
    }
    list
}

#[uniffi::export]
pub fn app_lock_min_password_chars() -> u32 {
    count(zapfast::app_lock::MIN_PASSWORD_CHARS)
}

/// A stored verifier for an app-lock password (upstream's salted PBKDF2).
/// Slow on purpose: call it off the main thread.
#[uniffi::export]
pub fn app_lock_verifier(password: String) -> String {
    zapfast::app_lock::verifier(&password)
}

/// Whether `password` matches an app-lock verifier. Slow on purpose.
#[uniffi::export]
pub fn app_lock_verifies(stored: String, password: String) -> bool {
    zapfast::app_lock::verifies(&stored, &password)
}

/// Seconds the next unlock try waits after `failures` wrong passwords in a
/// row (upstream's `wait_after`).
#[uniffi::export]
pub fn app_lock_wait_seconds(failures: u32) -> u64 {
    zapfast::app_lock::wait_after(failures).as_secs()
}

/// A stored verifier for the local code that opens locked chats, or `None`
/// for a blank code (upstream's `Settings::set_chat_lock_code`). Slow.
#[uniffi::export]
pub fn chat_lock_verifier(code: String) -> Option<String> {
    let mut settings = zapfast::settings::Settings::default();
    settings.set_chat_lock_code(Some(&code));
    settings.chat_lock_code_hash
}

/// Whether `code` opens locked chats (upstream's
/// `Settings::verifies_chat_lock_code`). Slow on purpose.
#[uniffi::export]
pub fn chat_lock_verifies(stored: String, code: String) -> bool {
    zapfast::settings::Settings {
        chat_lock_code_hash: Some(stored),
        ..Default::default()
    }
    .verifies_chat_lock_code(&code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_voice_note_upstream_encoded() {
        let rate = voice_sample_rate() as usize;
        let tone: Vec<f32> = (0..rate)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.3)
            .collect();
        let bytes = zapfast::voice::encode(&tone).unwrap();
        let path =
            std::env::temp_dir().join(format!("zapfast-bridge-voice-{}.ogg", std::process::id()));
        std::fs::write(&path, bytes).unwrap();

        let decoded = decode_voice(path.to_string_lossy().into_owned()).unwrap();
        std::fs::remove_file(&path).ok();

        // One second in, one second out, give or take Opus framing.
        assert!(
            (decoded.len() as i64 - rate as i64).abs() < rate as i64 / 10,
            "{}",
            decoded.len()
        );
    }

    #[test]
    fn reports_an_unreadable_file() {
        assert!(matches!(
            decode_voice("/nonexistent/voice.ogg".into()),
            Err(BridgeError::Media { .. })
        ));
    }

    #[test]
    fn formats_phone_ids_like_upstream() {
        assert_eq!(
            phone_of("998901234567@s.whatsapp.net".into()).as_deref(),
            Some("+99 890 123 456 7")
        );
        assert_eq!(phone_of("123@g.us".into()), None);
    }

    #[test]
    fn finds_stickers_by_emoji_name_through_upstream() {
        let library = StickerLibrary {
            favorites: vec!["/s/laugh.webp".into()],
            packs: vec![],
            recent: vec!["/s/heart.webp".into()],
            received: vec![],
            emojis: vec![
                crate::types::StickerEmojis {
                    path: "/s/laugh.webp".into(),
                    emojis: vec!["😂".into()],
                },
                crate::types::StickerEmojis {
                    path: "/s/heart.webp".into(),
                    emojis: vec!["❤️".into()],
                },
            ],
        };
        assert_eq!(
            search_stickers(library.clone(), "😂".into()),
            ["/s/laugh.webp"]
        );
        assert_eq!(search_stickers(library, "   ".into()), Vec::<String>::new());
    }

    #[test]
    fn our_giphy_key_wins_once_trimmed() {
        assert_eq!(giphy_key("  abc ".into()).as_deref(), Some("abc"));
    }

    #[test]
    fn app_lock_and_chat_lock_verifiers_round_trip() {
        let stored = app_lock_verifier("correct horse".into());
        assert!(app_lock_verifies(stored.clone(), "correct horse".into()));
        assert!(!app_lock_verifies(stored, "wrong horse".into()));
        assert_eq!(app_lock_wait_seconds(0), 0);
        assert!(app_lock_wait_seconds(10) > 0);

        let code = chat_lock_verifier(" 1234 ".into()).unwrap();
        assert!(chat_lock_verifies(code.clone(), "1234".into()));
        assert!(!chat_lock_verifies(code, "4321".into()));
        assert_eq!(chat_lock_verifier("  ".into()), None);
    }

    #[test]
    fn wallpaper_colours_and_ink_follow_upstream() {
        let light = wallpaper_colors(false);
        assert_eq!(light.len(), 28);
        assert_eq!(light[0].hex, "#f5f1eb");
        assert_eq!(wallpaper_colors(true).len(), 21);
        let dark_ink = doodle_ink("#f5f1eb".into());
        let light_ink = doodle_ink("#161717".into());
        let red = |ink: &str| u8::from_str_radix(&ink[1..3], 16).unwrap();
        assert!(red(&dark_ink) < 0x40, "{dark_ink}");
        assert!(red(&light_ink) > 0xe0, "{light_ink}");
        assert_eq!(dark_ink.len(), 9);
    }

    #[test]
    fn emoji_suggestions_rank_as_upstreams() {
        let first = |query: &str| {
            emoji_suggestions(query.into(), vec![])
                .first()
                .map(|found| found.emoji.clone())
        };
        assert_eq!(first("grinning").as_deref(), Some("😀"));
        assert!(
            emoji_suggestions("thumbsup".into(), vec![])
                .iter()
                .any(|found| found.emoji == "👍")
        );
        assert!(
            emoji_suggestions("pregnant".into(), vec![])
                .iter()
                .any(|found| found.emoji == "🤰")
        );
        assert_eq!(
            emoji_suggestions("GRINNING".into(), vec![])[0].shortcode,
            ":grinning:"
        );
        let recent = emoji_suggestions(String::new(), vec!["🚀".into(), "nope".into()]);
        assert_eq!(recent.len(), 6);
        assert_eq!(recent[0].emoji, "🚀");
        assert!(emoji_suggestions("zzzzqqq".into(), vec![]).is_empty());
    }

    #[test]
    fn the_picker_and_quick_reactions_follow_upstream() {
        let groups = emoji_groups();
        assert_eq!(groups.len(), 9);
        assert_eq!(groups[0].name, "Smileys & Emotion");
        assert!(groups[0].emoji.contains(&"😀".to_owned()));
        assert!(emoji_search("rocket".into()).contains(&"🚀".to_owned()));
        assert!(emoji_search("  ".into()).is_empty());

        assert_eq!(
            quick_reactions(vec![], None),
            ["👍", "❤️", "😂", "😮", "😢", "🙏"]
        );
        let preferred = quick_reactions(
            vec!["🔥".into(), "nope".into(), "👍".into()],
            Some("🎉".into()),
        );
        assert_eq!(preferred, ["🔥", "👍", "❤️", "😂", "😮", "😢", "🎉"]);
    }

    #[test]
    fn poll_drafts_follow_upstream_rules() {
        let draft = |options: &[&str]| PollDraftInfo {
            question: "Lunch?".into(),
            options: options.iter().map(|option| option.to_string()).collect(),
            multiple: false,
        };
        assert_eq!(poll_draft_problem(draft(&["Rice", "Soup"])), None);
        assert!(poll_draft_problem(draft(&["Rice"])).is_some());
        assert!(poll_draft_problem(draft(&["Rice", " Rice "])).is_some());
    }
}
