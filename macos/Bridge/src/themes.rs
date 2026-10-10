//! Upstream's JSON palettes, for the Mac's chat themes.
//!
//! Upstream themes its whole interface from palette files: a few shared with
//! Spotifast come built in, and more can be dropped in a folder. The Mac's
//! interface keeps the system's colours, so a palette becomes a chat theme
//! here: the conversation's background and our bubbles. The files are read
//! by upstream's own code (`fastframe_theme::parse_palette` with ZapFast's
//! palette), which fills the chat colours a Spotifast palette leaves out.

use std::path::Path;

use zapfast::theme::Palette;

/// A palette's colours a chat theme uses, `#rrggbb` each.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PaletteTheme {
    /// The name shown: the file name without `.json`.
    pub name: String,
    /// Made for dark appearance.
    pub dark: bool,
    /// Behind the messages.
    pub chat: String,
    pub bubble_in: String,
    pub bubble_out: String,
    pub accent: String,
    pub text: String,
}

impl PaletteTheme {
    fn new(filename: &str, palette: &Palette) -> Self {
        Self {
            name: fastframe_theme::display_name(filename).to_owned(),
            dark: palette.dark,
            chat: hex(palette.chat),
            bubble_in: hex(palette.bubble_in),
            bubble_out: hex(palette.bubble_out),
            accent: hex(palette.accent),
            text: hex(palette.text),
        }
    }
}

fn hex(color: ecolor::Color32) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r(), color.g(), color.b())
}

/// The palettes upstream ships, by name.
#[uniffi::export]
pub fn palette_presets() -> Vec<PaletteTheme> {
    let mut themes: Vec<PaletteTheme> = zapfast::theme::presets()
        .map(|theme| PaletteTheme::new(&theme.filename, &theme.palette))
        .collect();
    themes.sort_by(|a, b| a.name.cmp(&b.name));
    themes
}

/// The `.json` palettes in `folder`, by name; a file that does not read as
/// one is left out, and a missing folder has none.
#[uniffi::export]
pub fn palette_themes_in(folder: String) -> Vec<PaletteTheme> {
    let Ok(entries) = std::fs::read_dir(Path::new(&folder)) else {
        return Vec::new();
    };
    let mut themes: Vec<PaletteTheme> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.to_ascii_lowercase().ends_with(".json") {
                return None;
            }
            let text = std::fs::read_to_string(entry.path()).ok()?;
            match fastframe_theme::parse_palette::<Palette>(&text) {
                Ok(palette) => Some(PaletteTheme::new(&name, &palette)),
                Err(_) => {
                    log::info!("themes: a palette file did not read");
                    None
                }
            }
        })
        .collect();
    themes.sort_by(|a, b| a.name.cmp(&b.name));
    themes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shared_palettes_come_with_their_chat_colours() {
        let presets = palette_presets();
        let nord = presets
            .iter()
            .find(|theme| theme.name == "Nord")
            .expect("Nord ships");
        assert!(nord.dark);
        // Nord sets the window but not the chat: the chat follows the window.
        assert_eq!(nord.chat, "#2e3440");
        assert!(nord.bubble_out.starts_with('#') && nord.bubble_out.len() == 7);
    }

    #[test]
    fn a_folder_gives_its_palettes_and_skips_what_is_not_one() {
        let folder = std::env::temp_dir().join(format!("zapfast-palettes-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join("Mine.json"),
            r##"{"base":"light","colors":{"window":"#ffffff","accent":"#ff0000"}}"##,
        )
        .unwrap();
        std::fs::write(folder.join("Broken.json"), "{ not json").unwrap();
        std::fs::write(folder.join("notes.txt"), "hello").unwrap();

        let themes = palette_themes_in(folder.to_string_lossy().into_owned());
        assert_eq!(themes.len(), 1);
        assert_eq!(themes[0].name, "Mine");
        assert!(!themes[0].dark);
        assert_eq!(themes[0].chat, "#ffffff");
        assert_eq!(themes[0].accent, "#ff0000");
        assert!(palette_themes_in("/nowhere/at/all".into()).is_empty());
        std::fs::remove_dir_all(&folder).ok();
    }
}
