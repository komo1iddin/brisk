//! One-to-one voice calls.
//!
//! Upstream's interface has no calls, so its worker neither places nor
//! answers them. whatsapp-rust does both; the bridge turns its VoIP features on
//! (see `Cargo.toml`) and receives each worker's client through
//! `zapfast::backend::set_client_hook`. Everything else stays upstream's.
//!
//! Each account has a call center of its own, with its own client and call
//! history: a call rings for, and is placed from, one account.
//!
//! Swift sees each call as a [`CallInfo`] and drives it through
//! [`CallCenter`]: one with media, and one more that may ring beside it.
//! Audio crosses as 16 kHz mono `i16` frames of [`FRAME_SAMPLES`] each way:
//! Swift captures and plays them (the system's voice processing cancels the
//! echo), the library encodes, encrypts and carries them.
//!
//! Video crosses as H.264 access units (see [`video`]). Group calls are
//! voice only; a third call is left to ring on the phone.

mod history;
mod phase;
mod session;
mod video;

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, Once};

pub use history::{CallLogEntry, CallOutcome};
pub use phase::{CallEndReason, CallPhase};
pub use video::VideoFrameInfo;

use session::Center;

/// Samples in one audio frame each way: 60 ms at 16 kHz.
pub const FRAME_SAMPLES: u32 = 960;

/// The call shown to the person.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CallInfo {
    /// This app's own number for the call, new for each one.
    pub session: u64,
    /// The other side's chat id.
    pub chat: String,
    pub incoming: bool,
    /// The call was offered (or placed) as a video call.
    pub video_offered: bool,
    pub phase: CallPhase,
    pub muted: bool,
    /// Our camera is on: Swift captures and pushes frames.
    pub camera: bool,
    /// The other side's video is arriving.
    pub peer_video: bool,
    /// The other side asks to turn this voice call to video.
    pub video_requested: bool,
    /// A group's call: `chat` is the group.
    pub group: bool,
    /// Who rang us, in a group call.
    pub caller: Option<String>,
    /// The group call's other members, in the roster's order.
    pub participants: Vec<CallParticipant>,
}

/// A member of a group call.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CallParticipant {
    pub chat: String,
    /// In the call, rather than still being rung.
    pub joined: bool,
}

/// Receives call changes and the other side's audio, on background threads.
#[uniffi::export(with_foreign)]
pub trait CallListener: Send + Sync {
    /// The call changed. An ended call is reported once and then forgotten.
    fn on_call(&self, call: CallInfo);
    /// One frame of the other side's audio to play.
    fn on_playout(&self, samples: Vec<i16>);
    /// A call was added to (or changed in) a chat's history.
    fn on_call_log(&self, entry: CallLogEntry);
    /// One access unit of the other side's video to decode.
    fn on_video(&self, frame: VideoFrameInfo);
    /// The camera's encoder should make its next frame a keyframe.
    fn on_keyframe_needed(&self);
}

/// Places, answers and ends calls.
#[derive(uniffi::Object)]
pub struct CallCenter {
    center: Arc<Center>,
}

/// Each account's call center, by account id.
static CENTERS: LazyLock<Mutex<HashMap<String, Arc<CallCenter>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn centers() -> std::sync::MutexGuard<'static, HashMap<String, Arc<CallCenter>>> {
    CENTERS.lock().unwrap_or_else(|p| p.into_inner())
}

/// Hands the workers' clients to their accounts' call centers. Runs before
/// the first backend starts, so no client is missed.
pub(crate) fn install() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        if !zapfast::backend::set_client_hook(Box::new(|account, client| {
            // The one hook upstream allows: the link module shares the client.
            crate::link::made(account.as_str(), &client);
            center_for(account.as_str()).center.link(client);
        })) {
            log::warn!("calls: another client hook is installed; calls are off");
        }
    });
}

/// The call center of `account`, made the first time it is asked for.
pub(crate) fn center_for(account: &str) -> Arc<CallCenter> {
    centers()
        .entry(account.to_owned())
        .or_insert_with(|| {
            Arc::new(CallCenter {
                center: Center::new(),
            })
        })
        .clone()
}

/// Lets go of a removed account's call center.
pub(crate) fn forget(account: &str) {
    centers().remove(account);
}

#[uniffi::export]
impl CallCenter {
    /// The call center of account `account`.
    #[uniffi::constructor]
    pub fn for_account(account: String) -> Arc<Self> {
        center_for(&account)
    }

    pub fn set_listener(&self, listener: Arc<dyn CallListener>) {
        self.center.set_listener(listener);
    }

    /// Calls a person's chat. `false` when it cannot start now: another call
    /// rings or goes, the link is down, or the chat is not a person's.
    pub fn place(&self, chat: String, video: bool) -> bool {
        self.center.place(chat, video)
    }

    /// Answers ringing call `session`, with our camera on if `video`, first
    /// ending the call that goes, if any: WhatsApp has no hold.
    pub fn answer(&self, session: u64, video: bool) {
        self.center.answer(session, video);
    }

    /// Turns our camera on or off in the call that goes.
    pub fn set_camera(&self, on: bool) {
        self.center.set_camera(on);
    }

    /// One encoded camera frame: an Annex-B access unit, captured at
    /// `timestamp` on the 90 kHz clock.
    pub fn push_video(&self, data: Vec<u8>, timestamp: u32) {
        self.center.push_video(data, timestamp);
    }

    /// Asks the other side for a keyframe after a decoding loss.
    pub fn request_keyframe(&self) {
        self.center.request_keyframe();
    }

    /// Declines call `session` if it rings, or ends it.
    pub fn end(&self, session: u64) {
        self.center.end(session);
    }

    pub fn set_muted(&self, muted: bool) {
        self.center.set_muted(muted);
    }

    /// One frame of microphone audio, [`FRAME_SAMPLES`] long.
    pub fn push_microphone(&self, samples: Vec<i16>) {
        self.center.push_microphone(samples);
    }

    /// The live calls, oldest first.
    pub fn current(&self) -> Vec<CallInfo> {
        self.center.current()
    }

    /// A chat's calls, oldest first; empty until the bridge has started.
    pub fn history(&self, chat: String) -> Vec<CallLogEntry> {
        self.center.history(&chat)
    }
}

/// Opens an account's call history in its state folder. Without it calls
/// still work; they are only not remembered.
pub(crate) fn open_log(account: &str, state: &std::path::Path) {
    let center = center_for(account);
    match history::CallLog::open(&state.join("calls.db")) {
        Ok(store) => center.center.set_log(Arc::new(store)),
        Err(_) => log::warn!("calls: the call history could not be opened"),
    }
}

/// Moves the call history from the folder of a single-account setup into
/// account 1's, with its key, and brings back one an earlier build moved
/// without it. Neither stops the app: calls work without their history.
pub(crate) fn adopt_history(old_folder: &std::path::Path, account_folder: &std::path::Path) {
    let from = old_folder.join("calls.db");
    let to = account_folder.join("calls.db");
    if let Err(error) = history::move_to(&from, &to) {
        log::warn!("calls: the call history was not moved: {error:#}");
    }
    match history::recover_set_aside(old_folder, &to) {
        Ok(true) => log::info!("calls: brought back a call history set aside after a move"),
        Ok(false) => {}
        Err(error) => log::warn!("calls: a set-aside call history was not brought back: {error:#}"),
    }
}

/// Frames per second the camera is encoded at, for Swift.
#[uniffi::export]
pub fn call_video_frame_rate() -> u32 {
    video::FRAME_RATE
}

/// Samples in one call audio frame, for Swift.
#[uniffi::export]
pub fn call_frame_samples() -> u32 {
    FRAME_SAMPLES
}
