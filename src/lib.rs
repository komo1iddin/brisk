//! ZapFast internals exposed for diagnostics and tests.

//! Everything but the engine sits behind the `ui` feature: the window, the
//! views, and the desktop shell. A host that draws its own interface takes
//! the crate without it (`default-features = false`) and links neither egui
//! nor eframe.

#[cfg(feature = "ui")]
pub mod account;
#[cfg(feature = "ui")]
pub mod animation;
#[cfg(feature = "ui")]
pub mod app;
pub mod app_lock;
pub mod archive;
pub mod audio;
#[cfg(feature = "ui")]
pub mod autostart;
pub mod backend;
#[cfg(feature = "ui")]
pub mod bidi;
#[cfg(all(feature = "ui", any(test, feature = "demo")))]
pub mod demo;
pub mod diagnostics;
#[cfg(feature = "ui")]
pub mod emoji;
pub mod frames;
pub mod i18n;
#[cfg(feature = "ui")]
pub mod image_cache;
#[cfg(feature = "ui")]
pub mod image_preview;
#[cfg(all(feature = "ui", target_os = "macos"))]
pub mod macos;
#[cfg(feature = "ui")]
pub mod markup;
#[cfg(feature = "ui")]
pub mod media_pause;
pub mod model;
pub mod notify;
pub mod opener;
pub mod paths;
pub mod privacy;
pub mod proxy;
#[cfg(feature = "ui")]
pub mod qr;
pub mod safety;
pub mod settings;
#[cfg(feature = "ui")]
pub mod single_instance;
pub mod sticker_meta;
pub mod sticker_search;
pub mod theme;
pub mod timestretch;
#[cfg(feature = "ui")]
pub mod transcript;
pub mod transport;
#[cfg(feature = "ui")]
pub mod ui;
pub mod updates;
pub mod util;
#[cfg(feature = "ui")]
pub mod video;
pub mod voice;
pub mod wallpaper;
#[cfg(feature = "ui")]
pub mod window;
