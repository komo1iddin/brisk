//! The chat wallpaper: a colour, the default doodles over it, or an image of
//! the reader's own in place of both.
//!
//! Copying an image in, bounding it and choosing the doodles' tint are the
//! engine's: a host that draws its own conversation still imports the
//! reader's picture and asks what colour the doodles take. Drawing one is
//! `paint`, behind the `ui` feature and re-exported here.

use std::path::{Path, PathBuf};

use ecolor::Color32;

#[cfg(feature = "ui")]
mod paint;
#[cfg(feature = "ui")]
pub use paint::*;

/// The longest side a wallpaper image keeps, which bounds its texture to about
/// 26 MB even for a square picture while staying sharp on a 1440p display.
pub const MAX_SIDE: u32 = 2560;

/// The extensions a copied wallpaper image may have.
const EXTENSIONS: [&str; 4] = ["jpg", "png", "webp", "gif"];

/// The doodles' tint over `background`: whichever of near-black or white
/// stands further from it, as opaque as it takes to differ from the
/// background by a fixed step. Any theme colour then shows the doodles about
/// as faintly as WhatsApp's own colours do, mid-tones included.
pub fn doodle_ink(background: Color32) -> Color32 {
    const DARK_INK: u8 = 30;
    const LIGHT_INK: u8 = 255;
    let luma = 0.2126 * f32::from(background.r())
        + 0.7152 * f32::from(background.g())
        + 0.0722 * f32::from(background.b());
    let (ink, step) = if luma - f32::from(DARK_INK) > f32::from(LIGHT_INK) - luma {
        (DARK_INK, 23.2)
    } else {
        (LIGHT_INK, 38.0)
    };
    let distance = (luma - f32::from(ink)).abs().max(1.0);
    let alpha = (step / distance).clamp(0.1, 0.4);
    Color32::from_rgba_unmultiplied(ink, ink, ink, (alpha * 255.0).round() as u8)
}

fn bounded(image: image::DynamicImage) -> image::DynamicImage {
    if image.width().max(image.height()) > MAX_SIDE {
        image.resize(MAX_SIDE, MAX_SIDE, image::imageops::FilterType::Triangle)
    } else {
        image
    }
}

/// Copies a chosen image to ZapFast's own `wallpaper.<ext>`, so the original
/// may move or go. An image larger than [`MAX_SIDE`] is scaled down first and
/// stored as JPEG, or PNG when it has transparency; a smaller one is copied as
/// it is. Earlier copies are removed once the new one is in place.
pub fn import(source: &Path, state: &Path) -> Result<PathBuf, String> {
    let bytes = std::fs::read(source).map_err(|error| error.to_string())?;
    let format = image::guess_format(&bytes).map_err(|_| "not an image".to_owned())?;
    let decoded =
        image::load_from_memory_with_format(&bytes, format).map_err(|error| error.to_string())?;
    let (contents, extension) = if decoded.width().max(decoded.height()) > MAX_SIDE {
        encode(&bounded(decoded))?
    } else {
        let extension = match format {
            image::ImageFormat::Jpeg => "jpg",
            image::ImageFormat::Png => "png",
            image::ImageFormat::WebP => "webp",
            image::ImageFormat::Gif => "gif",
            _ => return Err("unsupported image format".to_owned()),
        };
        (bytes, extension)
    };
    std::fs::create_dir_all(state).map_err(|error| error.to_string())?;
    let target = state.join(format!("wallpaper.{extension}"));
    let temporary = state.join("wallpaper.tmp");
    std::fs::write(&temporary, contents)
        .and_then(|()| std::fs::rename(&temporary, &target))
        .map_err(|error| {
            let _ = std::fs::remove_file(&temporary);
            error.to_string()
        })?;
    for other in EXTENSIONS.into_iter().filter(|other| *other != extension) {
        let _ = std::fs::remove_file(state.join(format!("wallpaper.{other}")));
    }
    Ok(target)
}

fn encode(image: &image::DynamicImage) -> Result<(Vec<u8>, &'static str), String> {
    let mut contents = Vec::new();
    let extension = if image.color().has_alpha() {
        image
            .write_to(
                &mut std::io::Cursor::new(&mut contents),
                image::ImageFormat::Png,
            )
            .map_err(|error| error.to_string())?;
        "png"
    } else {
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut contents, 90)
            .encode_image(&image.to_rgb8())
            .map_err(|error| error.to_string())?;
        "jpg"
    };
    Ok((contents, extension))
}

/// Deletes ZapFast's copy of the wallpaper image, whatever its extension.
pub fn remove(state: &Path) {
    for extension in EXTENSIONS {
        match std::fs::remove_file(state.join(format!("wallpaper.{extension}"))) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => log::debug!("could not delete the wallpaper image: {error}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doodles_show_on_every_background() {
        for level in 0..=255u8 {
            for background in [
                Color32::from_rgb(level, level, level),
                Color32::from_rgb(level, 0, 0),
                Color32::from_rgb(0, level, level / 2),
            ] {
                let ink = doodle_ink(background).to_srgba_unmultiplied();
                let alpha = f32::from(ink[3]) / 255.0;
                let over = |channel: u8, ink: u8| {
                    f32::from(channel) * (1.0 - alpha) + f32::from(ink) * alpha
                };
                let luma = |r: f32, g: f32, b: f32| 0.2126 * r + 0.7152 * g + 0.0722 * b;
                let before = luma(
                    f32::from(background.r()),
                    f32::from(background.g()),
                    f32::from(background.b()),
                );
                let after = luma(
                    over(background.r(), ink[0]),
                    over(background.g(), ink[1]),
                    over(background.b(), ink[2]),
                );
                assert!(
                    (after - before).abs() >= 20.0,
                    "doodles fade into {background:?}: {before} to {after}"
                );
            }
        }
        // WhatsApp's own light and dark defaults keep their familiar look.
        assert_eq!(ink_alpha(doodle_ink(Color32::from_rgb(245, 241, 235))), 28);
        assert_eq!(ink_alpha(doodle_ink(Color32::from_rgb(22, 23, 23))), 42);
    }

    fn ink_alpha(ink: Color32) -> u8 {
        ink.to_srgba_unmultiplied()[3]
    }
}
