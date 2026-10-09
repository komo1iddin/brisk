//! Playback for WhatsApp GIFs, animated WebP stickers, and GIF files.
//!
//! Decoding runs off the UI thread. WebP, GIF, and H.264 MP4 decode in-process;
//! other MP4 codecs use `ffmpeg` when available. Idle animations are removed
//! from memory, and a paused one keeps only its first frame, the poster, until
//! it plays.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use egui::{ColorImage, TextureHandle, TextureOptions};

use crate::frames::{Decoded, MAX_FRAMES, decode};

/// Time an unseen animation remains decoded.
const IDLE: Duration = Duration::from_secs(20);
/// Global texture-frame budget. Least-recently-used animations are removed first.
const MAX_RESIDENT_FRAMES: usize = 450;

struct Playing {
    frames: Vec<(TextureHandle, Duration)>,
    total: Duration,
    started: Instant,
    last_drawn: Instant,
    animating: bool,
    /// Whether every frame is decoded. A paused animation decodes only its
    /// poster: a picker full of animated stickers would otherwise hold more
    /// frames than the budget, and each decode would evict a visible tile that
    /// then decodes again, flickering endlessly (#165).
    complete: bool,
    /// A decode of every frame is running for this poster.
    upgrading: bool,
}

enum Entry {
    Decoding,
    Failed,
    Ready(Playing),
}

/// Resident animations plus the bookkeeping the eviction sweep needs.
#[derive(Default)]
struct Animations {
    entries: HashMap<PathBuf, Entry>,
    /// Paths a sweep found idle. A `frame` call for the path clears the mark,
    /// so only an animation that misses a whole sweep interval undrawn is
    /// evicted.
    idle: HashSet<PathBuf>,
    /// When the eviction sweep last ran.
    last_sweep: Option<Instant>,
}

#[derive(Clone, Default)]
struct Cache(Arc<Mutex<Animations>>);

/// Result returned by a decoder thread, and whether it holds every frame
/// rather than only the poster.
type Delivery = (PathBuf, Option<Decoded>, bool);

/// Decoded frames waiting for texture upload.
#[derive(Clone, Default)]
struct Inbox(Arc<Mutex<Vec<Delivery>>>);

fn cache(ctx: &egui::Context) -> Cache {
    ctx.data_mut(|data| {
        data.get_temp_mut_or_default::<Cache>(egui::Id::new("animations"))
            .clone()
    })
}

fn inbox(ctx: &egui::Context) -> Inbox {
    ctx.data_mut(|data| {
        data.get_temp_mut_or_default::<Inbox>(egui::Id::new("animation-inbox"))
            .clone()
    })
}

/// Current display state for an animated file.
pub enum Frame {
    /// Current animation frame.
    Ready(TextureHandle),
    /// Decode in progress; show the poster.
    Pending,
    /// Unsupported in-app; show the poster and allow opening the file.
    Unavailable,
}

/// Returns the current frame, starting decoding when needed.
///
/// A visible but paused animation returns its first frame without scheduling
/// another repaint. This keeps animated media idle until playback is wanted.
pub fn frame(ui: &egui::Ui, path: &Path, rect: egui::Rect, animate: bool) -> Frame {
    // ScrollArea still lays out clipped rows. They must neither start decoders
    // nor keep the window repainting while their pixels are off screen.
    if !ui.is_rect_visible(rect) {
        return Frame::Pending;
    }
    let ctx = ui.ctx();
    let cache = cache(ctx);
    let inbox = inbox(ctx);
    // Upload decoded frames on the UI thread.
    let arrived: Vec<Delivery> =
        std::mem::take(&mut *inbox.0.lock().unwrap_or_else(|p| p.into_inner()));
    let mut animations = cache.0.lock().unwrap_or_else(|p| p.into_inner());
    let uploaded = !arrived.is_empty();
    for (arrived_path, decoded, complete) in arrived {
        let entry = match decoded {
            Some(_)
                if !complete
                    && matches!(
                        animations.entries.get(&arrived_path),
                        Some(Entry::Ready(playing)) if playing.complete
                    ) =>
            {
                // Every frame is already here; a late poster adds nothing.
                continue;
            }
            Some(decoded) if !decoded.frames.is_empty() => {
                let mut total = Duration::ZERO;
                let frames = decoded
                    .frames
                    .into_iter()
                    .enumerate()
                    .map(|(index, (image, delay))| {
                        total += delay;
                        let name = format!("{}#{index}", arrived_path.display());
                        (
                            ctx.load_texture(name, to_color_image(&image), TextureOptions::LINEAR),
                            delay,
                        )
                    })
                    .collect();
                Entry::Ready(Playing {
                    frames,
                    total: total.max(Duration::from_millis(50)),
                    started: Instant::now(),
                    last_drawn: Instant::now(),
                    animating: false,
                    complete,
                    upgrading: false,
                })
            }
            _ => match animations.entries.get_mut(&arrived_path) {
                // A poster whose other frames failed stays a still picture
                // instead of asking again on every frame.
                Some(Entry::Ready(playing)) => {
                    playing.upgrading = false;
                    playing.complete = true;
                    continue;
                }
                _ => Entry::Failed,
            },
        };
        animations.entries.insert(arrived_path, entry);
    }
    let now = Instant::now();
    // Refresh the animation being drawn before the sweep: its own `frame` call
    // is the only proof that it is on screen, and a sibling drawn later in this
    // same pass has not had that chance yet.
    if let Some(Entry::Ready(playing)) = animations.entries.get_mut(path) {
        playing.last_drawn = now;
    }
    animations.idle.remove(path);
    // Eviction is rate limited to one sweep per `IDLE` instead of running
    // inside every `frame` call, and a sweep only marks what it finds idle.
    // With vsync off and event-driven repaints a visible, paused animation can
    // sit longer than `IDLE` without being drawn, so a sweep cannot tell "off
    // screen" from "not visited yet in this pass": evicting either would
    // re-decode media that is still on screen and flash the poster. The mark
    // is cleared by the next `frame` call for the path, so only an animation
    // that misses a whole sweep interval undrawn is evicted. That trades up to
    // one extra `IDLE` of resident frames for a stable poster while the media
    // is visible.
    if animations
        .last_sweep
        .is_none_or(|last| now.duration_since(last) >= IDLE)
    {
        animations.last_sweep = Some(now);
        let previously_idle = std::mem::take(&mut animations.idle);
        let mut idle = HashSet::new();
        animations.entries.retain(|entry_path, entry| match entry {
            Entry::Ready(playing) if now.duration_since(playing.last_drawn) >= IDLE => {
                if previously_idle.contains(entry_path) {
                    false
                } else {
                    idle.insert(entry_path.clone());
                    true
                }
            }
            _ => true,
        });
        animations.idle = idle;
        enforce_budget(&mut animations, path, now);
    } else if uploaded {
        // New frames can exceed the budget between sweeps.
        enforce_budget(&mut animations, path, now);
    }
    match animations.entries.get_mut(path) {
        Some(Entry::Ready(playing)) => {
            if !animate {
                playing.animating = false;
                return Frame::Ready(playing.frames[0].0.clone());
            }
            if !playing.complete {
                // Keep showing the poster while the other frames decode.
                if !playing.upgrading {
                    match start_decode(ctx, &inbox, path, true) {
                        Start::Started => playing.upgrading = true,
                        Start::Busy => {
                            ctx.request_repaint_after(Duration::from_millis(150));
                        }
                        Start::Failed => playing.complete = true,
                    }
                }
                return Frame::Ready(playing.frames[0].0.clone());
            }
            if !playing.animating {
                playing.started = now;
                playing.animating = true;
            }
            let elapsed = now.duration_since(playing.started);
            let mut position =
                Duration::from_nanos((elapsed.as_nanos() % playing.total.as_nanos()) as u64);
            let mut chosen = 0;
            let mut until_next = Duration::from_millis(40);
            for (index, (_, delay)) in playing.frames.iter().enumerate() {
                if position < *delay {
                    chosen = index;
                    until_next = *delay - position;
                    break;
                }
                position -= *delay;
            }
            if playing.frames.len() > 1 {
                ctx.request_repaint_after(until_next.max(Duration::from_millis(10)));
            }
            Frame::Ready(playing.frames[chosen].0.clone())
        }
        Some(Entry::Decoding) => Frame::Pending,
        Some(Entry::Failed) => Frame::Unavailable,
        None => match start_decode(ctx, &inbox, path, animate) {
            Start::Started => {
                animations
                    .entries
                    .insert(path.to_path_buf(), Entry::Decoding);
                Frame::Pending
            }
            Start::Busy => {
                // Retry shortly when all decoder slots are busy.
                ctx.request_repaint_after(Duration::from_millis(150));
                Frame::Pending
            }
            Start::Failed => {
                animations.entries.insert(path.to_path_buf(), Entry::Failed);
                Frame::Unavailable
            }
        },
    }
}

/// Whether a decoder thread could be started.
enum Start {
    Started,
    /// Every decoder slot is taken; try again shortly.
    Busy,
    Failed,
}

/// Decodes `path` on a thread, every frame when `all` and otherwise only the
/// poster, and delivers the result to `inbox`.
fn start_decode(ctx: &egui::Context, inbox: &Inbox, path: &Path, all: bool) -> Start {
    let Some(slot) = crate::frames::claim_slot() else {
        return Start::Busy;
    };
    let file = path.to_path_buf();
    let ctx = ctx.clone();
    let inbox = inbox.clone();
    let limit = if all { MAX_FRAMES } else { 1 };
    let spawned = std::thread::Builder::new()
        .name("animation-decode".into())
        .spawn(move || {
            let _slot = slot;
            // Convert decoder panics to failed results.
            let decoded =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| decode(&file, limit)))
                    .unwrap_or(None);
            inbox
                .0
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .push((file, decoded, all));
            ctx.request_repaint();
        });
    if spawned.is_err() {
        return Start::Failed;
    }
    Start::Started
}

/// The one place a decoded frame becomes something egui can upload.
fn to_color_image(image: &image::RgbaImage) -> ColorImage {
    ColorImage::from_rgba_unmultiplied(
        [image.width() as usize, image.height() as usize],
        image.as_raw(),
    )
}

/// Frame `index` of a video (or its last, if shorter), for demo posters.
#[cfg(any(test, feature = "demo"))]
pub(crate) fn video_frame(path: &Path, index: usize) -> Option<ColorImage> {
    crate::frames::decode_video(path, index + 1)?
        .frames
        .pop()
        .map(|(image, _)| to_color_image(&image))
}

/// Trims animations until the resident frames fit the budget, sparing the
/// one being drawn. What the last sweep found idle goes first; an animation
/// drawn since only drops back to its poster, so a tile that is still on
/// screen never flashes its placeholder, and posters go last.
fn enforce_budget(animations: &mut Animations, path: &Path, now: Instant) {
    let mut resident: usize = animations
        .entries
        .values()
        .map(|entry| match entry {
            Entry::Ready(playing) => playing.frames.len(),
            _ => 0,
        })
        .sum();
    while resident > MAX_RESIDENT_FRAMES {
        let victim = animations
            .entries
            .iter()
            .filter(|(entry_path, entry)| {
                entry_path.as_path() != path && matches!(entry, Entry::Ready(_))
            })
            .min_by_key(|(entry_path, entry)| match entry {
                Entry::Ready(playing) => (
                    u8::from(!animations.idle.contains(*entry_path)),
                    u8::from(playing.frames.len() == 1),
                    playing.last_drawn,
                ),
                _ => (1, 1, now),
            })
            .map(|(entry_path, _)| entry_path.clone());
        let Some(victim) = victim else {
            break;
        };
        let idle = animations.idle.contains(&victim);
        match animations.entries.get_mut(&victim) {
            Some(Entry::Ready(playing)) if !idle && playing.frames.len() > 1 => {
                resident -= playing.frames.len() - 1;
                playing.frames.truncate(1);
                playing.complete = false;
                playing.upgrading = false;
                playing.animating = false;
            }
            Some(Entry::Ready(playing)) => {
                resident -= playing.frames.len();
                animations.entries.remove(&victim);
            }
            _ => {
                animations.entries.remove(&victim);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn clipped_animation_does_not_decode_or_schedule_frames() {
        let ctx = egui::Context::default();
        let path = std::path::Path::new("offscreen.gif");
        let mut delay = Duration::ZERO;
        for index in 0..4 {
            let mut output = ctx.run_ui(
                egui::RawInput {
                    time: Some(index as f64),
                    screen_rect: Some(egui::Rect::from_min_size(
                        egui::Pos2::ZERO,
                        egui::vec2(200.0, 200.0),
                    )),
                    ..Default::default()
                },
                |ui| {
                    let rect =
                        egui::Rect::from_min_size(egui::pos2(0.0, 1000.0), egui::vec2(50.0, 50.0));
                    assert!(matches!(
                        super::frame(ui, path, rect, true),
                        super::Frame::Pending
                    ));
                },
            );
            delay = output.viewport_output[&egui::ViewportId::ROOT].repaint_delay;
            output.textures_delta.clear();
        }
        assert!(super::cache(&ctx).0.lock().unwrap().entries.is_empty());
        assert!(
            delay > Duration::from_secs(1),
            "offscreen media requested {delay:?}"
        );
    }

    use super::*;

    #[test]
    fn a_paused_animation_stays_idle_and_restarts_at_the_first_frame() {
        let ctx = egui::Context::default();
        let path = PathBuf::from("paused.gif");
        let frames = [egui::Color32::WHITE, egui::Color32::BLACK]
            .into_iter()
            .enumerate()
            .map(|(index, color)| {
                (
                    ctx.load_texture(
                        format!("paused-frame-{index}"),
                        ColorImage::new([1, 1], vec![color]),
                        TextureOptions::LINEAR,
                    ),
                    Duration::from_secs(60),
                )
            })
            .collect::<Vec<_>>();
        let first = frames[0].0.id();
        cache(&ctx)
            .0
            .lock()
            .expect("animation cache")
            .entries
            .insert(
                path.clone(),
                Entry::Ready(Playing {
                    frames,
                    total: Duration::from_secs(120),
                    // Without a playback-state reset, the next animated pass
                    // would land halfway through the second frame.
                    started: Instant::now() - Duration::from_secs(90),
                    last_drawn: Instant::now(),
                    animating: false,
                    complete: true,
                    upgrading: false,
                }),
            );
        // Settle texture uploads before checking the paused frame itself.
        for _ in 0..3 {
            let mut output = ctx.run_ui(egui::RawInput::default(), |_| {});
            output.textures_delta.clear();
        }
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(200.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(frame(ui, &path, rect, false), Frame::Ready(_)));
            },
        );
        let delay = output.viewport_output[&egui::ViewportId::ROOT].repaint_delay;
        output.textures_delta.clear();
        assert!(
            delay > Duration::from_secs(1),
            "a paused frame requested another repaint after {delay:?}"
        );

        let mut resumed = None;
        let mut output = ctx.run_ui(egui::RawInput::default(), |ui| {
            let (rect, _) = ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
            if let Frame::Ready(texture) = frame(ui, &path, rect, true) {
                resumed = Some(texture.id());
            }
        });
        output.textures_delta.clear();
        assert_eq!(resumed, Some(first));
    }

    #[test]
    fn a_visible_animation_is_not_evicted_or_redecoded_while_idle() {
        let ctx = egui::Context::default();
        let path = PathBuf::from("idle-visible.gif");
        let frames = [egui::Color32::WHITE, egui::Color32::BLACK]
            .into_iter()
            .enumerate()
            .map(|(index, color)| {
                (
                    ctx.load_texture(
                        format!("idle-visible-frame-{index}"),
                        ColorImage::new([1, 1], vec![color]),
                        TextureOptions::LINEAR,
                    ),
                    Duration::from_secs(60),
                )
            })
            .collect::<Vec<_>>();
        let first = frames[0].0.id();
        cache(&ctx)
            .0
            .lock()
            .expect("animation cache")
            .entries
            .insert(
                path.clone(),
                Entry::Ready(Playing {
                    frames,
                    total: Duration::from_secs(120),
                    started: Instant::now(),
                    // A visible animation whose last draw was long ago: with
                    // event-driven repaints it can go this long without a frame.
                    last_drawn: Instant::now() - IDLE - Duration::from_secs(10),
                    animating: false,
                    complete: true,
                    upgrading: false,
                }),
            );
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(200.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(frame(ui, &path, rect, false), Frame::Ready(_)));
            },
        );
        output.textures_delta.clear();
        // Still decoded, same first frame: not evicted, not re-decoded.
        let store = cache(&ctx);
        let animations = store.0.lock().expect("animation cache");
        let entries = &animations.entries;
        let Entry::Ready(playing) = entries.get(&path).expect("still cached") else {
            panic!("the visible animation was evicted");
        };
        assert_eq!(playing.frames[0].0.id(), first);
    }

    #[test]
    fn an_unseen_animation_is_evicted_after_idle() {
        let ctx = egui::Context::default();
        let stale = PathBuf::from("stale.gif");
        let fresh = PathBuf::from("fresh.gif");
        let frames = |name: &str| {
            [egui::Color32::WHITE, egui::Color32::BLACK]
                .into_iter()
                .enumerate()
                .map(|(index, color)| {
                    (
                        ctx.load_texture(
                            format!("{name}-frame-{index}"),
                            ColorImage::new([1, 1], vec![color]),
                            TextureOptions::LINEAR,
                        ),
                        Duration::from_secs(60),
                    )
                })
                .collect::<Vec<_>>()
        };
        cache(&ctx)
            .0
            .lock()
            .expect("animation cache")
            .entries
            .insert(
                stale.clone(),
                Entry::Ready(Playing {
                    frames: frames("stale"),
                    total: Duration::from_secs(120),
                    started: Instant::now(),
                    last_drawn: Instant::now() - IDLE - Duration::from_secs(10),
                    animating: false,
                    complete: true,
                    upgrading: false,
                }),
            );
        cache(&ctx)
            .0
            .lock()
            .expect("animation cache")
            .entries
            .insert(
                fresh.clone(),
                Entry::Ready(Playing {
                    frames: frames("fresh"),
                    total: Duration::from_secs(120),
                    started: Instant::now(),
                    last_drawn: Instant::now(),
                    animating: false,
                    complete: true,
                    upgrading: false,
                }),
            );
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(200.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(frame(ui, &fresh, rect, false), Frame::Ready(_)));
            },
        );
        output.textures_delta.clear();
        // A sweep cannot tell an animation that is off screen from one that has
        // not had its `frame` call yet in this pass, so it only marks what it
        // finds idle.
        {
            let store = cache(&ctx);
            let animations = store.0.lock().expect("animation cache");
            assert!(
                animations.entries.contains_key(&stale),
                "the first sweep only marks the unseen animation"
            );
            assert!(
                animations.idle.contains(&stale),
                "the unseen path is marked"
            );
        }
        // A whole sweep later it is still undrawn, so it is evicted.
        {
            let store = cache(&ctx);
            let mut animations = store.0.lock().expect("animation cache");
            animations.last_sweep = Some(Instant::now() - IDLE - Duration::from_secs(10));
            let Entry::Ready(playing) = animations
                .entries
                .get_mut(&stale)
                .expect("the marked animation is still cached")
            else {
                panic!("the unseen animation was evicted before its second sweep");
            };
            playing.last_drawn = Instant::now() - IDLE - Duration::from_secs(20);
        }
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(200.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(frame(ui, &fresh, rect, false), Frame::Ready(_)));
            },
        );
        output.textures_delta.clear();
        let store = cache(&ctx);
        let animations = store.0.lock().expect("animation cache");
        assert!(
            animations.entries.contains_key(&fresh),
            "the drawn animation stays"
        );
        assert!(
            !animations.entries.contains_key(&stale),
            "an unseen animation must be evicted once it misses a sweep"
        );
    }

    #[test]
    fn frames_arriving_between_sweeps_still_respect_the_budget() {
        let ctx = egui::Context::default();
        let old = PathBuf::from("old.gif");
        let new = PathBuf::from("new.gif");
        let count = MAX_RESIDENT_FRAMES / 2 + 1;
        let frames: Vec<_> = (0..count)
            .map(|index| {
                (
                    ctx.load_texture(
                        format!("old-frame-{index}"),
                        ColorImage::new([1, 1], vec![egui::Color32::WHITE]),
                        TextureOptions::LINEAR,
                    ),
                    Duration::from_millis(50),
                )
            })
            .collect();
        {
            let store = cache(&ctx);
            let mut animations = store.0.lock().expect("animation cache");
            animations.entries.insert(
                old.clone(),
                Entry::Ready(Playing {
                    frames,
                    total: Duration::from_secs(10),
                    started: Instant::now(),
                    last_drawn: Instant::now() - Duration::from_secs(1),
                    animating: false,
                    complete: true,
                    upgrading: false,
                }),
            );
            // No sweep is due during this frame.
            animations.last_sweep = Some(Instant::now());
        }
        inbox(&ctx).0.lock().expect("inbox").push((
            new.clone(),
            Some(Decoded {
                frames: (0..count)
                    .map(|_| {
                        (
                            image::RgbaImage::from_pixel(1, 1, image::Rgba([0, 0, 0, 255])),
                            Duration::from_millis(50),
                        )
                    })
                    .collect(),
            }),
            true,
        ));
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(200.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(frame(ui, &new, rect, false), Frame::Ready(_)));
            },
        );
        output.textures_delta.clear();
        let store = cache(&ctx);
        let animations = store.0.lock().expect("animation cache");
        assert!(
            animations.entries.contains_key(&new),
            "the drawn animation stays"
        );
        // The old animation was drawn a second ago and may still be on
        // screen, so it keeps its poster instead of flashing a placeholder.
        let Some(Entry::Ready(old)) = animations.entries.get(&old) else {
            panic!("a recently drawn animation keeps its poster");
        };
        assert_eq!(old.frames.len(), 1);
        assert!(!old.complete, "it decodes again when it next plays");
    }

    /// An animated WebP of `count` 8x8 frames that all differ.
    fn animated_webp(dir: &Path, name: &str, count: i32) -> PathBuf {
        let mut encoder = webp_animation::Encoder::new((8, 8)).expect("encoder");
        for index in 0..count {
            let shade = (index * 255 / count) as u8;
            let frame =
                image::RgbaImage::from_pixel(8, 8, image::Rgba([shade, 0, 255 - shade, 255]));
            encoder.add_frame(&frame, index * 40).expect("frame");
        }
        let webp = encoder.finalize(count * 40).expect("finalizes");
        let path = dir.join(name);
        std::fs::write(&path, &*webp).expect("writes");
        path
    }

    /// Draws `paths` side by side, on screen, returning what each showed.
    fn draw_all(ctx: &egui::Context, paths: &[PathBuf], animate: bool) -> Vec<Frame> {
        let mut shown = Vec::new();
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(800.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                ui.horizontal(|ui| {
                    for path in paths {
                        let (rect, _) =
                            ui.allocate_exact_size(egui::vec2(40.0, 40.0), egui::Sense::hover());
                        shown.push(frame(ui, path, rect, animate));
                    }
                });
            },
        );
        output.textures_delta.clear();
        shown
    }

    /// Draws until every path shows a frame, or panics after a few seconds.
    fn settle(ctx: &egui::Context, paths: &[PathBuf], animate: bool) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !draw_all(ctx, paths, animate)
            .iter()
            .all(|shown| matches!(shown, Frame::Ready(_)))
        {
            assert!(Instant::now() < deadline, "the animations never settled");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn paused_stickers_beyond_the_frame_budget_stay_on_screen() {
        // A sticker picker full of animated stickers holds more frames than
        // the budget. Fully decoded, each arrival evicted a tile still on
        // screen, which decoded again and evicted another: tiles flickered
        // between the sticker and its placeholder for as long as the picker
        // stayed open (#165).
        let dir = std::env::temp_dir().join(format!("zapfast-budget-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let per_file = 80;
        let paths: Vec<_> = (0..MAX_RESIDENT_FRAMES / per_file as usize + 2)
            .map(|index| animated_webp(&dir, &format!("tile-{index}.webp"), per_file))
            .collect();
        let ctx = egui::Context::default();
        settle(&ctx, &paths, false);
        for _ in 0..30 {
            let shown = draw_all(&ctx, &paths, false);
            assert!(
                shown.iter().all(|shown| matches!(shown, Frame::Ready(_))),
                "a visible paused sticker fell back to its placeholder"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let store = cache(&ctx);
        let animations = store.0.lock().expect("animation cache");
        for path in &paths {
            let Some(Entry::Ready(playing)) = animations.entries.get(path) else {
                panic!("{} is not resident", path.display());
            };
            assert_eq!(playing.frames.len(), 1, "a paused sticker holds its poster");
        }
        drop(animations);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_poster_plays_every_frame_without_a_placeholder_in_between() {
        let dir = std::env::temp_dir().join(format!("zapfast-poster-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let paths = vec![animated_webp(&dir, "hover.webp", 3)];
        let ctx = egui::Context::default();
        settle(&ctx, &paths, false);
        let poster = match &draw_all(&ctx, &paths, false)[0] {
            Frame::Ready(texture) => texture.id(),
            _ => panic!("the poster is resident"),
        };
        // Hovering shows the poster until the other frames arrive.
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let shown = draw_all(&ctx, &paths, true);
            let Frame::Ready(texture) = &shown[0] else {
                panic!("playing a poster showed a placeholder");
            };
            let complete = matches!(
                cache(&ctx).0.lock().expect("cache").entries.get(&paths[0]),
                Some(Entry::Ready(playing)) if playing.complete
            );
            if complete {
                break;
            }
            assert_eq!(texture.id(), poster);
            assert!(Instant::now() < deadline, "the other frames never arrived");
            std::thread::sleep(Duration::from_millis(10));
        }
        let store = cache(&ctx);
        let animations = store.0.lock().expect("animation cache");
        let Some(Entry::Ready(playing)) = animations.entries.get(&paths[0]) else {
            panic!("the animation is resident");
        };
        assert_eq!(playing.frames.len(), 3);
        drop(animations);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_sibling_drawn_in_the_same_pass_survives_the_sweep() {
        // Two paused animations that are both on screen and both past `IDLE`,
        // the state an event-driven repaint wakes up in. The first item's
        // `frame` call runs the sweep and must not evict the second before that
        // item's own call in this pass, which would re-decode it and flash the
        // poster: exactly the flicker this module avoids.
        let ctx = egui::Context::default();
        let first_path = PathBuf::from("sibling-first.gif");
        let second_path = PathBuf::from("sibling-second.gif");
        let frames = |name: &str| {
            [egui::Color32::WHITE, egui::Color32::BLACK]
                .into_iter()
                .enumerate()
                .map(|(index, color)| {
                    (
                        ctx.load_texture(
                            format!("{name}-frame-{index}"),
                            ColorImage::new([1, 1], vec![color]),
                            TextureOptions::LINEAR,
                        ),
                        Duration::from_secs(60),
                    )
                })
                .collect::<Vec<_>>()
        };
        let mut first_textures = Vec::new();
        for (name, path) in [("first", &first_path), ("second", &second_path)] {
            let playing_frames = frames(name);
            first_textures.push(playing_frames[0].0.id());
            cache(&ctx)
                .0
                .lock()
                .expect("animation cache")
                .entries
                .insert(
                    path.clone(),
                    Entry::Ready(Playing {
                        frames: playing_frames,
                        total: Duration::from_secs(120),
                        started: Instant::now(),
                        last_drawn: Instant::now() - IDLE - Duration::from_secs(10),
                        animating: false,
                        complete: true,
                        upgrading: false,
                    }),
                );
        }
        // The next `frame` call is due to sweep.
        cache(&ctx).0.lock().expect("animation cache").last_sweep =
            Some(Instant::now() - IDLE - Duration::from_secs(10));
        let mut output = ctx.run_ui(
            egui::RawInput {
                screen_rect: Some(egui::Rect::from_min_size(
                    egui::Pos2::ZERO,
                    egui::vec2(200.0, 200.0),
                )),
                ..Default::default()
            },
            |ui| {
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(
                    frame(ui, &first_path, rect, false),
                    Frame::Ready(_)
                ));
                let (rect, _) =
                    ui.allocate_exact_size(egui::vec2(50.0, 50.0), egui::Sense::hover());
                assert!(matches!(
                    frame(ui, &second_path, rect, false),
                    Frame::Ready(_)
                ));
            },
        );
        output.textures_delta.clear();
        let store = cache(&ctx);
        let animations = store.0.lock().expect("animation cache");
        let Entry::Ready(second) = animations
            .entries
            .get(&second_path)
            .expect("the sibling survives the sweep the first draw triggered")
        else {
            panic!("the second animation was evicted before its own frame call");
        };
        assert_eq!(
            second.frames[0].0.id(),
            first_textures[1],
            "the sibling keeps its decoded frames instead of re-decoding"
        );
    }
}
