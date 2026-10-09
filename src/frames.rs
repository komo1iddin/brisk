//! Decodes pictures, animations and video to frames.
//!
//! WebP and GIF frames decode in-process, and so do MP4s: the `mp4` crate
//! demuxes, `openh264` decodes the H.264 WhatsApp uses (samples converted
//! from AVCC to Annex B), and `ffmpeg` is only a fallback for other codecs.
//! A frame comes out as an `image::RgbaImage`, held to `MAX_WIDTH`: what a
//! caller does with it afterwards is its own business, so nothing here knows
//! about textures or the drawing library. [`crate::animation`] uploads these
//! frames as textures; the worker reads a `Poster` off an outgoing video
//! without drawing anything at all.

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

/// Maximum frame width uploaded to the GPU.
pub(crate) const MAX_WIDTH: u32 = 320;

/// Maximum frames kept per animation.
pub(crate) const MAX_FRAMES: usize = 150;

/// Maximum concurrent decoders.
const MAX_DECODERS: usize = 2;

static DECODING: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Guard for one decoder slot; dropping it frees the slot again.
pub(crate) struct DecodeSlot;

/// Takes a decoder slot, or `None` when both are busy. Decoding is bounded
/// because each decoder holds a whole clip's frames while it works.
pub(crate) fn claim_slot() -> Option<DecodeSlot> {
    if DECODING.load(std::sync::atomic::Ordering::Acquire) >= MAX_DECODERS {
        return None;
    }
    DECODING.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
    Some(DecodeSlot)
}

impl Drop for DecodeSlot {
    fn drop(&mut self) {
        DECODING.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
    }
}

pub(crate) struct Decoded {
    pub(crate) frames: Vec<(image::RgbaImage, Duration)>,
}

/// MP4 playback is always available because H.264 decodes in-process.
pub fn can_play_video() -> bool {
    true
}

/// Whether `ffmpeg` is available for other MP4 codecs.
fn ffmpeg_present() -> bool {
    static KNOWN: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *KNOWN.get_or_init(|| {
        Command::new("ffmpeg")
            .arg("-version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    })
}

/// Decodes up to `limit` frames.
pub(crate) fn decode(path: &Path, limit: usize) -> Option<Decoded> {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "webp" | "gif" => decode_image(path, &extension, limit),
        _ => decode_video(path, limit),
    }
}

/// Decodes animated GIF with the `image` crate.
fn decode_image(path: &Path, extension: &str, limit: usize) -> Option<Decoded> {
    use image::AnimationDecoder;
    if extension != "gif" {
        return decode_webp(path, limit);
    }
    let file = std::fs::File::open(path).ok()?;
    let reader = std::io::BufReader::new(file);
    let frames = image::codecs::gif::GifDecoder::new(reader)
        .ok()?
        .into_frames();
    let mut decoded = Vec::new();
    for frame in frames.take(limit) {
        let frame = frame.ok()?;
        let (numerator, denominator) = frame.delay().numer_denom_ms();
        let delay = Duration::from_millis(u64::from(numerator / denominator.max(1)).max(20));
        let image = frame.into_buffer();
        decoded.push((within_budget(&image), delay));
    }
    Some(Decoded { frames: decoded })
}

/// Decodes animated WebP with libwebp. It returns complete canvas frames,
/// unlike the `image` decoder, which did not apply frame disposal correctly.
fn decode_webp(path: &Path, limit: usize) -> Option<Decoded> {
    let bytes = std::fs::read(path).ok()?;
    let decoder = webp_animation::Decoder::new(&bytes).ok()?;
    let (width, height) = decoder.dimensions();
    let mut decoded = Vec::new();
    let mut previous = 0i64;
    // A second frame tells an animation from a still, even for a poster.
    for frame in decoder.into_iter().take(limit.max(2)) {
        let image = image::RgbaImage::from_raw(width, height, frame.data().to_vec())?;
        let delay = (i64::from(frame.timestamp()) - previous).max(20) as u64;
        previous = i64::from(frame.timestamp());
        decoded.push((within_budget(&image), Duration::from_millis(delay)));
    }
    // Single-frame files use the static-image path.
    if decoded.len() < 2 {
        return None;
    }
    decoded.truncate(limit);
    Some(Decoded { frames: decoded })
}

/// Holds a decoded frame to `MAX_WIDTH`, which is what bounds the memory a
/// resident animation costs. Decoding scales; drawing does not.
fn within_budget(image: &image::RgbaImage) -> image::RgbaImage {
    if image.width() <= MAX_WIDTH {
        return image.clone();
    }
    let height = (image.height() * MAX_WIDTH / image.width()).max(1);
    image::imageops::resize(
        image,
        MAX_WIDTH,
        height,
        image::imageops::FilterType::Triangle,
    )
}

/// Decodes MP4 to scaled RGBA frames with `ffmpeg`.
pub(crate) fn decode_video(path: &Path, limit: usize) -> Option<Decoded> {
    // Decode WhatsApp's H.264 MP4s in-process and use ffmpeg for other codecs.
    decode_mp4(path, limit).or_else(|| decode_with_ffmpeg(path, limit))
}

/// Decodes an MP4 video track in-process.
fn decode_mp4(path: &Path, limit: usize) -> Option<Decoded> {
    let file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    decode_mp4_from(std::io::BufReader::new(file), size, limit)
}

/// Decodes the video track of an MP4 of `size` bytes read from `reader`.
fn decode_mp4_from<R: std::io::Read + std::io::Seek>(
    reader: R,
    size: u64,
    limit: usize,
) -> Option<Decoded> {
    let mut mp4 = mp4::Mp4Reader::read_header(reader, size).ok()?;
    let (track_id, timescale, sps, pps, count) = {
        let track = mp4
            .tracks()
            .values()
            .find(|track| track.track_type().ok() == Some(mp4::TrackType::Video))?;
        (
            track.track_id(),
            u64::from(track.timescale().max(1)),
            track.sequence_parameter_set().ok()?.to_vec(),
            track.picture_parameter_set().ok()?.to_vec(),
            track.sample_count(),
        )
    };
    let mut decoder = openh264::decoder::Decoder::new().ok()?;
    let mut frames: Vec<(image::RgbaImage, Duration)> = Vec::new();
    let mut delays: std::collections::VecDeque<Duration> = std::collections::VecDeque::new();
    // Send parameter sets and samples to the decoder in Annex B format.
    let mut parameters = Vec::new();
    push_annex_b(&mut parameters, &sps);
    push_annex_b(&mut parameters, &pps);
    let _ = decoder.decode(&parameters);
    for sample_id in 1..=count {
        if frames.len() >= limit {
            break;
        }
        let Ok(Some(sample)) = mp4.read_sample(track_id, sample_id) else {
            break;
        };
        let delay =
            Duration::from_millis((u64::from(sample.duration) * 1000 / timescale).clamp(20, 1000));
        delays.push_back(delay);
        let mut annex_b = Vec::with_capacity(sample.bytes.len() + 16);
        avcc_to_annex_b(&mut annex_b, &sample.bytes);
        if let Ok(Some(yuv)) = decoder.decode(&annex_b) {
            let delay = delays.pop_front().unwrap_or(delay);
            if let Some(frame) = frame_of(&yuv, delay) {
                frames.push(frame);
            }
        }
    }
    if let Ok(rest) = decoder.flush_remaining() {
        for yuv in &rest {
            if frames.len() >= limit {
                break;
            }
            let delay = delays.pop_front().unwrap_or(Duration::from_millis(66));
            if let Some(frame) = frame_of(yuv, delay) {
                frames.push(frame);
            }
        }
    }
    (!frames.is_empty()).then_some(Decoded { frames })
}

/// What an MP4 says about itself, with a picture from its start: what the
/// message sending it carries, so it shows as a video before it is downloaded.
pub(crate) struct Poster {
    /// A frame about a second in (openings are often black), scaled down.
    /// `None` when the codec is not one decoded in-process.
    pub picture: Option<image::RgbImage>,
    pub width: u32,
    pub height: u32,
    pub seconds: u32,
}

/// Reads the size, length, and a poster frame of the MP4 in `bytes`.
pub(crate) fn poster(bytes: &[u8]) -> Option<Poster> {
    let size = bytes.len() as u64;
    let mp4 = mp4::Mp4Reader::read_header(std::io::Cursor::new(bytes), size).ok()?;
    let track = mp4
        .tracks()
        .values()
        .find(|track| track.track_type().ok() == Some(mp4::TrackType::Video))?;
    let (width, height) = (u32::from(track.width()), u32::from(track.height()));
    let seconds = mp4.duration().as_secs_f64().round() as u32;
    // A second in, within what a sixty-frame clip costs to decode.
    let frames = (track.frame_rate().round() as usize).clamp(1, 60);
    let picture = decode_mp4_from(std::io::Cursor::new(bytes), size, frames)
        .and_then(|decoded| decoded.frames.into_iter().last())
        .map(|(frame, _)| image::DynamicImage::ImageRgba8(frame).into_rgb8());
    (width > 0 && height > 0).then_some(Poster {
        picture,
        width,
        height,
        seconds,
    })
}

/// Converts and scales one decoded frame.
fn frame_of(
    yuv: &openh264::decoder::DecodedYUV<'_>,
    delay: Duration,
) -> Option<(image::RgbaImage, Duration)> {
    use openh264::formats::YUVSource;

    let (width, height) = yuv.dimensions();
    if width == 0 || height == 0 {
        return None;
    }
    let mut rgba = vec![0u8; width * height * 4];
    yuv.write_rgba8(&mut rgba);
    let image = image::RgbaImage::from_raw(width as u32, height as u32, rgba)?;
    let out_width = (width as u32).min(MAX_WIDTH);
    let out_height = ((height as u64 * out_width as u64 / width as u64) as u32).max(1);
    let scaled = if out_width == width as u32 {
        image
    } else {
        image::imageops::resize(
            &image,
            out_width,
            out_height,
            image::imageops::FilterType::Triangle,
        )
    };
    Some((scaled, delay))
}

pub(crate) fn push_annex_b(out: &mut Vec<u8>, nal: &[u8]) {
    out.extend_from_slice(&[0, 0, 0, 1]);
    out.extend_from_slice(nal);
}

/// Converts length-prefixed AVCC NAL units to Annex B start codes.
pub(crate) fn avcc_to_annex_b(out: &mut Vec<u8>, sample: &[u8]) {
    let mut rest = sample;
    while rest.len() >= 4 {
        let length = u32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
        rest = &rest[4..];
        if length == 0 || length > rest.len() {
            break;
        }
        push_annex_b(out, &rest[..length]);
        rest = &rest[length..];
    }
}

fn decode_with_ffmpeg(path: &Path, limit: usize) -> Option<Decoded> {
    if !ffmpeg_present() {
        return None;
    }
    let probe = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height",
            "-of",
            "csv=p=0",
        ])
        .arg(path)
        .output()
        .ok()?;
    let dimensions = String::from_utf8_lossy(&probe.stdout);
    let mut parts = dimensions.trim().split(',');
    let width: u32 = parts.next()?.trim().parse().ok()?;
    let height: u32 = parts.next()?.trim().parse().ok()?;
    if width == 0 || height == 0 {
        return None;
    }
    let out_width = width.min(MAX_WIDTH);
    // Use even dimensions and preserve aspect ratio.
    let out_height = ((height as u64 * out_width as u64 / width as u64) as u32).max(2) & !1;
    let fps = 15u32;
    let mut child = Command::new("ffmpeg")
        .args(["-v", "error", "-i"])
        .arg(path)
        .args([
            "-an",
            "-vf",
            &format!("fps={fps},scale={out_width}:{out_height}"),
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgba",
            "pipe:1",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let frame_bytes = (out_width * out_height * 4) as usize;
    let mut frames = Vec::new();
    let delay = Duration::from_millis(1000 / u64::from(fps));
    let mut buffer = vec![0u8; frame_bytes];
    while frames.len() < limit {
        if stdout.read_exact(&mut buffer).is_err() {
            break;
        }
        let Some(frame) = image::RgbaImage::from_raw(out_width, out_height, buffer.clone()) else {
            break;
        };
        frames.push((frame, delay));
    }
    let _ = child.kill();
    let _ = child.wait();
    (!frames.is_empty()).then_some(Decoded { frames })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A video being sent gets its picture, size, and length from its bytes.
    #[test]
    fn a_video_says_its_size_and_length_and_shows_a_frame() {
        let bytes = include_bytes!("../tests/fixtures/video/sample.mp4");
        let poster = poster(bytes).expect("an MP4");
        assert_eq!((poster.width, poster.height, poster.seconds), (320, 180, 3));
        let picture = poster.picture.expect("H.264 decodes in-process");
        assert_eq!(picture.width() * 180, picture.height() * 320);
        // Bars of colour, not a blank frame.
        let first = picture.get_pixel(4, picture.height() / 2);
        let last = picture.get_pixel(picture.width() - 4, picture.height() / 2);
        assert_ne!(first, last);
        assert!(super::poster(b"not a video").is_none());
    }

    /// Verifies animated WebP frame disposal.
    #[test]
    fn a_moving_subject_leaves_no_trace_behind() {
        use webp_animation::prelude::*;
        let side = 64u32;
        let square = |x0: u32, y0: u32, color: [u8; 4]| {
            let mut frame = vec![0u8; (side * side * 4) as usize];
            for y in y0..y0 + 16 {
                for x in x0..x0 + 16 {
                    let at = ((y * side + x) * 4) as usize;
                    frame[at..at + 4].copy_from_slice(&color);
                }
            }
            frame
        };
        let mut encoder = Encoder::new((side, side)).expect("encoder");
        encoder
            .add_frame(&square(0, 0, [255, 0, 0, 255]), 0)
            .expect("frame");
        encoder
            .add_frame(&square(40, 40, [0, 255, 0, 255]), 100)
            .expect("frame");
        let webp = encoder.finalize(200).expect("finalizes");
        let dir = std::env::temp_dir().join(format!("zapfast-ghost-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("moving.webp");
        std::fs::write(&path, &webp).expect("writes");
        let decoded = decode(&path, MAX_FRAMES).expect("decodes");
        assert_eq!(decoded.frames.len(), 2);
        let second = &decoded.frames[1].0;
        let old = second.get_pixel(8, 8);
        assert_eq!(old[3], 0, "the first frame's square is gone: {old:?}");
        let new = second.get_pixel(48, 48);
        assert!(new[3] > 200, "the second frame's square shows: {new:?}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn animated_webp_decodes_into_frames() {
        // Two frames 100 ms apart.
        let dir = std::env::temp_dir().join(format!("zapfast-anim-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("two.gif");
        {
            let file = std::fs::File::create(&path).expect("file");
            let mut encoder = image::codecs::gif::GifEncoder::new(file);
            encoder
                .set_repeat(image::codecs::gif::Repeat::Infinite)
                .expect("repeat");
            for shade in [40u8, 200u8] {
                let frame = image::Frame::from_parts(
                    image::RgbaImage::from_pixel(8, 8, image::Rgba([shade, shade, shade, 255])),
                    0,
                    0,
                    image::Delay::from_numer_denom_ms(100, 1),
                );
                encoder.encode_frame(frame).expect("frame");
            }
        }
        let decoded = decode(&path, MAX_FRAMES).expect("decodes");
        assert_eq!(decoded.frames.len(), 2);
        assert_eq!(decoded.frames[0].1, Duration::from_millis(100));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn an_mp4_made_by_ffmpeg_decodes_in_process() {
        if !can_play_video() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("zapfast-mp4-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("clip.mp4");
        let made = Command::new("ffmpeg")
            .args([
                "-v",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "testsrc=duration=0.5:size=64x48:rate=10",
            ])
            .args(["-pix_fmt", "yuv420p"])
            .arg(&path)
            .status()
            .is_ok_and(|status| status.success());
        if !made {
            // Skip when this ffmpeg lacks the encoder.
            return;
        }
        let decoded = decode(&path, MAX_FRAMES).expect("decodes");
        // Five frames at 10 fps. The in-process path preserves their timing.
        assert_eq!(decoded.frames.len(), 5);
        assert_eq!(decoded.frames[0].1, Duration::from_millis(100));
        assert_eq!(decoded.frames[0].0.dimensions(), (64, 48));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_still_webp_is_not_an_animation() {
        let dir = std::env::temp_dir().join(format!("zapfast-still-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("still.webp");
        image::RgbaImage::from_pixel(4, 4, image::Rgba([1, 2, 3, 255]))
            .save(&path)
            .expect("saves");
        assert!(decode(&path, MAX_FRAMES).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod probe {
    use super::*;
    use std::time::Instant;

    /// Decodes the file in `ZAPFAST_MP4_PROBE`:
    /// `ZAPFAST_MP4_PROBE=some.mp4 cargo test --all-features probe -- --ignored --nocapture`.
    #[test]
    #[ignore = "needs a file to look at"]
    fn decodes_the_file_named_by_the_environment() {
        let Some(path) = std::env::var_os("ZAPFAST_MP4_PROBE") else {
            return;
        };
        let started = Instant::now();
        let decoded = decode_mp4(Path::new(&path), MAX_FRAMES).expect("decodes in-process");
        eprintln!(
            "{} frames of {:?}, first delay {:?}, in {:?}",
            decoded.frames.len(),
            decoded.frames[0].0.dimensions(),
            decoded.frames[0].1,
            started.elapsed()
        );
        assert!(!decoded.frames.is_empty());
        let started = Instant::now();
        let bytes = std::fs::read(&path).expect("the file");
        let poster = poster(&bytes).expect("its size and length");
        eprintln!(
            "poster {:?} of {}x{}, {} s, in {:?}",
            poster.picture.as_ref().map(|picture| picture.dimensions()),
            poster.width,
            poster.height,
            poster.seconds,
            started.elapsed()
        );
    }
}
