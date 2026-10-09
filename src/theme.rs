//! Colours, metrics, icons, and the shared egui controls.
//!
//! The palette itself is plain data: what a theme file names, what the
//! settings remember, and the colours every view asks for. It carries no
//! egui styling, so a host drawing its own interface still reads the same
//! themes. Everything that styles an egui context lives in `style`, behind
//! the `ui` feature, and is re-exported here so call sites read the same.

use egui::Color32;

#[cfg(feature = "ui")]
mod style;
#[cfg(feature = "ui")]
pub use style::*;

/// A local JSON palette, known by its filename in the themes directory.
pub type CustomTheme = fastframe_theme::CustomTheme<Palette>;

/// The palettes Settings offers: local files, the shared presets, and on
/// Linux the live Omarchy palette.
pub type Catalog = fastframe_theme::Catalog<Palette>;

/// What a normal launch adds to the catalogue. Demos and tests leave it out
/// and stay isolated from the desktop and its files.
pub const DESKTOP_THEMES: fastframe_theme::DesktopThemes = fastframe_theme::DesktopThemes {
    slug: "zapfast",
    omarchy_template: include_str!("../contrib/omarchy/zapfast.json.tpl"),
    // Every template ZapFast shipped before, so an untouched copy installed
    // by an older release is replaced with the current one.
    omarchy_previous_templates: &[include_str!(
        "../contrib/omarchy/previous/zapfast-1.json.tpl"
    )],
    presets: true,
};

/// The shared palettes, as ZapFast reads them.
pub fn presets() -> impl Iterator<Item = CustomTheme> {
    fastframe_theme::presets::themes::<Palette>()
}

/// What the theme setting says under it while the catalogue loads or when
/// something went wrong.
pub fn theme_status(status: fastframe_theme::Status) -> &'static str {
    use fastframe_theme::{Problem, Status};
    match status {
        Status::Loading => "Loading local themes…",
        Status::SelectedUnavailable => {
            "The selected theme is unavailable. Keeping the last usable appearance. See the log for details."
        }
        Status::Problem(Problem::Unreadable) => {
            "The themes folder could not be read. See the log for details."
        }
        Status::Problem(Problem::TooManyEntries) => {
            "The themes folder has more than 512 entries. Keep fewer files there to list the custom palettes."
        }
        Status::Problem(Problem::TooManyThemes) => {
            "Only 128 custom palettes can be listed. Keep fewer JSON files in the themes folder to see the rest."
        }
        Status::Problem(Problem::OmarchyUnreadable) => {
            "The Omarchy palette could not be loaded. Keeping the last usable appearance. See the log for details."
        }
        Status::Problem(Problem::LoaderFailed | _) => {
            "Custom themes could not be loaded. Run zapfast reload-themes to try again."
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Palette {
    pub dark: bool,
    pub window: Color32,
    pub panel: Color32,
    pub surface: Color32,
    pub surface_hover: Color32,
    pub surface_active: Color32,
    pub outline: Color32,
    pub text: Color32,
    pub secondary: Color32,
    pub dim: Color32,
    pub accent: Color32,
    pub accent_hover: Color32,
    pub on_accent: Color32,
    pub danger: Color32,
    pub warning: Color32,
    pub overlay: Color32,
    pub shadow: Color32,
    /// Conversation background behind message bubbles.
    pub chat: Color32,
    /// Incoming message bubble.
    pub bubble_in: Color32,
    /// Outgoing message bubble.
    pub bubble_out: Color32,
    pub link: Color32,
    /// Read-receipt blue.
    pub read: Color32,
}

impl Palette {
    pub fn dark() -> Self {
        Self {
            dark: true,
            window: Color32::from_rgb(0x0b, 0x14, 0x1a),
            panel: Color32::from_rgb(0x11, 0x1b, 0x21),
            surface: Color32::from_rgb(0x20, 0x2c, 0x33),
            surface_hover: Color32::from_rgb(0x2a, 0x39, 0x42),
            surface_active: Color32::from_rgb(0x35, 0x44, 0x4d),
            outline: Color32::from_rgb(0x22, 0x2d, 0x34),
            text: Color32::from_rgb(0xe9, 0xed, 0xef),
            // Secondary and dim text reach WCAG AA (4.5:1) on the window,
            // panel, surface, and menu colours.
            secondary: Color32::from_rgb(0x97, 0xa5, 0xae),
            dim: Color32::from_rgb(0x8a, 0x98, 0x9f),
            accent: Color32::from_rgb(0x00, 0xa8, 0x84),
            accent_hover: Color32::from_rgb(0x06, 0xcf, 0x9c),
            on_accent: Color32::from_rgb(0x0b, 0x14, 0x1a),
            danger: Color32::from_rgb(0xf1, 0x5c, 0x6d),
            warning: Color32::from_rgb(0xff, 0xd2, 0x79),
            overlay: Color32::from_rgb(0x23, 0x31, 0x38),
            shadow: Color32::from_black_alpha(140),
            chat: Color32::from_rgb(0x0b, 0x14, 0x1a),
            bubble_in: Color32::from_rgb(0x20, 0x2c, 0x33),
            bubble_out: Color32::from_rgb(0x00, 0x5c, 0x4b),
            link: Color32::from_rgb(0x53, 0xbd, 0xeb),
            read: Color32::from_rgb(0x53, 0xbd, 0xeb),
        }
    }

    pub fn light() -> Self {
        Self {
            dark: false,
            window: Color32::from_rgb(0xf0, 0xf2, 0xf5),
            panel: Color32::from_rgb(0xff, 0xff, 0xff),
            surface: Color32::from_rgb(0xf0, 0xf2, 0xf5),
            surface_hover: Color32::from_rgb(0xe6, 0xe9, 0xec),
            surface_active: Color32::from_rgb(0xd9, 0xdd, 0xe1),
            outline: Color32::from_rgb(0xe9, 0xed, 0xef),
            text: Color32::from_rgb(0x11, 0x1b, 0x21),
            // Secondary and dim text reach WCAG AA (4.5:1) on the window,
            // panel, surface, chat, and menu colours. The accent is the green
            // WhatsApp uses in its light theme, readable as text on white and
            // under white button labels.
            secondary: Color32::from_rgb(0x51, 0x5f, 0x67),
            dim: Color32::from_rgb(0x63, 0x6b, 0x72),
            accent: Color32::from_rgb(0x00, 0x80, 0x69),
            accent_hover: Color32::from_rgb(0x00, 0x6e, 0x5a),
            on_accent: Color32::WHITE,
            danger: Color32::from_rgb(0xea, 0x00, 0x38),
            warning: Color32::from_rgb(0xa0, 0x6b, 0x00),
            overlay: Color32::from_rgb(0xff, 0xff, 0xff),
            shadow: Color32::from_black_alpha(LIGHT_SHADOW_ALPHA),
            chat: Color32::from_rgb(0xef, 0xea, 0xe2),
            bubble_in: Color32::from_rgb(0xff, 0xff, 0xff),
            bubble_out: Color32::from_rgb(0xd9, 0xfd, 0xd3),
            link: Color32::from_rgb(0x02, 0x7e, 0xb5),
            // The lighter blue vanished on the green outgoing bubble.
            read: Color32::from_rgb(0x02, 0x7e, 0xb5),
        }
    }

    /// The palette for a message bubble's contents. Secondary and dim text,
    /// and the read ticks, move toward the text colour just far enough to
    /// stay readable on the bubble: a grey that reads on the panel can vanish
    /// on the outgoing bubble. Works for custom themes as well.
    pub fn on_bubble(&self, own: bool) -> Self {
        let fill = if own { self.bubble_out } else { self.bubble_in };
        Self {
            secondary: readable_on(fill, self.secondary, self.text, 4.5),
            dim: readable_on(fill, self.dim, self.text, 4.5),
            // Icons need 3:1 (WCAG 1.4.11).
            read: readable_on(fill, self.read, self.text, 3.0),
            ..*self
        }
    }

    /// The soft shadow that lifts message bubbles and date chips off the
    /// wallpaper: two points down with a short blur, a little denser than
    /// the palette's own shadow colour, so custom themes steer it. A shadow
    /// alone barely darkens a dark chat; [`Palette::raised_edge`] lights
    /// the top as well.
    pub fn bubble_shadow(&self) -> egui::epaint::Shadow {
        egui::epaint::Shadow {
            offset: [0, 2],
            blur: 6,
            spread: 0,
            color: denser(self.lift_shadow(), SHADOW_DENSITY),
        }
    }

    /// The shadow under a surface that floats over the window for a moment:
    /// menus, toasts, the emoji picker, and egui's own popups.
    pub fn float_shadow(&self) -> egui::epaint::Shadow {
        egui::epaint::Shadow {
            offset: [0, 6],
            blur: 20,
            spread: 0,
            color: self.shadow,
        }
    }

    /// The deeper shadow under a modal surface that holds the window until
    /// it closes: dialogs, the update dialog, and the image preview.
    pub fn modal_shadow(&self) -> egui::epaint::Shadow {
        egui::epaint::Shadow {
            offset: [0, 12],
            blur: 40,
            spread: 0,
            color: self.shadow,
        }
    }

    /// The palette's shadow colour, no heavier than the light theme's: a
    /// dark palette's own shadow is meant for popups and menus, and under
    /// every bubble it weighed on an otherwise flat theme.
    pub fn lift_shadow(&self) -> Color32 {
        let [r, g, b, a] = self.shadow.to_srgba_unmultiplied();
        Color32::from_rgba_unmultiplied(r, g, b, a.min(LIGHT_SHADOW_ALPHA))
    }

    /// The faint light along the top edge of a raised surface of colour
    /// `fill`. In a dark theme the fill moves a little toward the text
    /// colour, so it follows every dark palette, mid-dark ones included; in
    /// a light one, where the text is dark, it moves toward white instead,
    /// which shows on tinted surfaces and vanishes on white ones.
    pub fn raised_edge(&self, fill: Color32) -> Color32 {
        if self.dark {
            fill.lerp_to_gamma(self.text, DARK_EDGE_TINT)
        } else {
            fill.lerp_to_gamma(Color32::WHITE, LIGHT_EDGE_TINT)
        }
    }

    /// Group-sender color derived from the avatar hue.
    pub fn sender(&self, hue: f32) -> Color32 {
        if self.dark {
            hsl(hue, 0.6, 0.68)
        } else {
            hsl(hue, 0.65, 0.38)
        }
    }

    /// Avatar background derived from the chat hue.
    pub fn avatar(&self, hue: f32) -> Color32 {
        let (saturation, lightness) = if self.dark {
            (0.38, 0.42)
        } else {
            (0.45, 0.62)
        };
        hsl(hue, saturation, lightness)
    }
}

impl fastframe_theme::Palette for Palette {
    fn base(base: fastframe_theme::Base) -> Self {
        match base {
            fastframe_theme::Base::Dark => Self::dark(),
            fastframe_theme::Base::Light => Self::light(),
        }
    }

    fn set(&mut self, name: &str, color: Color32) -> bool {
        match name {
            "window" => self.window = color,
            "panel" => self.panel = color,
            "surface" => self.surface = color,
            "surface_hover" => self.surface_hover = color,
            "surface_active" => self.surface_active = color,
            "outline" => self.outline = color,
            "text" => self.text = color,
            "secondary" => self.secondary = color,
            "dim" => self.dim = color,
            "accent" => self.accent = color,
            "accent_hover" => self.accent_hover = color,
            "on_accent" => self.on_accent = color,
            "danger" => self.danger = color,
            "warning" => self.warning = color,
            "overlay" => self.overlay = color,
            "shadow" => self.shadow = color,
            "chat" => self.chat = color,
            "bubble_in" => self.bubble_in = color,
            "bubble_out" => self.bubble_out = color,
            "link" => self.link = color,
            "read" => self.read = color,
            _ => return false,
        }
        true
    }

    /// Spotifast palettes share the sixteen interface colours. Derive the
    /// chat-only colours when importing one, while keeping explicit ZapFast
    /// overrides.
    fn derive(&mut self, given: &std::collections::BTreeSet<&str>) {
        if given.contains("window") && !given.contains("chat") {
            self.chat = self.window;
        }
        // Bubbles stand a little further from the chat than the interface's
        // surfaces do, keeping text on them at 4.5:1 in every shared palette.
        if given.contains("surface") && !given.contains("bubble_in") {
            self.bubble_in = self.surface.lerp_to_gamma(self.text, 0.05);
        }
        if given.contains("accent") {
            if !given.contains("bubble_out") {
                self.bubble_out = self.surface.lerp_to_gamma(self.accent, 0.24);
            }
            if !given.contains("link") {
                self.link = self.accent;
            }
            if !given.contains("read") {
                self.read = self.accent;
            }
        }
        if given.contains("panel") && !given.contains("overlay") {
            self.overlay = self.panel;
        }
    }
}

/// Mixes two colors; `t = 1` returns `b`.
pub fn blend(a: Color32, b: Color32, t: f32) -> Color32 {
    let mix = |x: u8, y: u8| (f32::from(x) + (f32::from(y) - f32::from(x)) * t).round() as u8;
    Color32::from_rgba_unmultiplied(
        mix(a.r(), b.r()),
        mix(a.g(), b.g()),
        mix(a.b(), b.b()),
        mix(a.a(), b.a()),
    )
}

/// WCAG contrast ratio between two opaque colours, from 1 to 21.
pub fn contrast(a: Color32, b: Color32) -> f32 {
    fn luminance(color: Color32) -> f32 {
        let channel = |value: u8| {
            let value = f32::from(value) / 255.0;
            if value <= 0.040_45 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * channel(color.r()) + 0.7152 * channel(color.g()) + 0.0722 * channel(color.b())
    }
    let (a, b) = (luminance(a), luminance(b));
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

/// `color`, blended toward `toward` only as far as needed to reach `target`
/// contrast on `background`.
pub fn readable_on(background: Color32, color: Color32, toward: Color32, target: f32) -> Color32 {
    let mut step = 0.0;
    loop {
        let candidate = blend(color, toward, step);
        if step >= 1.0 || contrast(candidate, background) >= target {
            return candidate;
        }
        step = (step + 0.05_f32).min(1.0);
    }
}

/// How much denser than the palette's shadow colour a bubble's shadow is.
const SHADOW_DENSITY: f32 = 1.04;
/// How far a dark theme's raised edge moves from the surface toward the text.
const DARK_EDGE_TINT: f32 = 0.128;
/// The light palette's shadow opacity, the most a raised surface casts.
const LIGHT_SHADOW_ALPHA: u8 = 50;
/// How far a light theme's raised edge moves from the surface toward white.
const LIGHT_EDGE_TINT: f32 = 0.48;
/// How thick the raised edge is, in points.
pub const RAISED_EDGE: f32 = 1.0;

/// `color` with its opacity scaled by `factor`, up to opaque.
fn denser(color: Color32, factor: f32) -> Color32 {
    let [r, g, b, a] = color.to_srgba_unmultiplied();
    let alpha = (f32::from(a) * factor).round().clamp(0.0, 255.0) as u8;
    Color32::from_rgba_unmultiplied(r, g, b, alpha)
}

/// Converts HSL to color bytes for non-egui drawing.
pub fn hsl_rgb(hue: f32, saturation: f32, lightness: f32) -> [u8; 3] {
    let color = hsl(hue, saturation, lightness);
    [color.r(), color.g(), color.b()]
}

fn hsl(hue: f32, saturation: f32, lightness: f32) -> Color32 {
    let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
    let sector = hue / 60.0;
    let x = chroma * (1.0 - (sector % 2.0 - 1.0).abs());
    let (r, g, b) = match sector as u32 {
        0 => (chroma, x, 0.0),
        1 => (x, chroma, 0.0),
        2 => (0.0, chroma, x),
        3 => (0.0, x, chroma),
        4 => (x, 0.0, chroma),
        _ => (chroma, 0.0, x),
    };
    let m = lightness - chroma / 2.0;
    let channel = |value: f32| ((value + m) * 255.0).round().clamp(0.0, 255.0) as u8;
    Color32::from_rgb(channel(r), channel(g), channel(b))
}
