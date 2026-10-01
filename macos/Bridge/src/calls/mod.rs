//! One-to-one voice calls.
//!
//! Upstream's interface has no calls, so its worker neither places nor
//! answers them. whatsapp-rust does both; the bridge turns its VoIP features on
//! (see `Cargo.toml`) and receives the worker's client through
//! `zapfast::backend::set_client_hook`. Everything else stays upstream's.
//!
//! Swift sees one call at a time as a [`CallInfo`] and drives it through
//! [`CallCenter`]. Audio crosses as 16 kHz mono `i16` frames of
//! [`FRAME_SAMPLES`] each way: Swift captures and plays them (the system's
//! voice processing cancels the echo), the library encodes, encrypts and
//! carries them.
//!
//! Video, group calls and a second call while one is going are not handled:
//! such an offer is left to ring on the phone.

mod phase;
mod session;

use std::sync::{Arc, OnceLock};

pub use phase::{CallEndReason, CallPhase};

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
    /// The caller asked for video; we answer with audio only.
    pub video_offered: bool,
    pub phase: CallPhase,
    pub muted: bool,
}

/// Receives call changes and the other side's audio, on background threads.
#[uniffi::export(with_foreign)]
pub trait CallListener: Send + Sync {
    /// The call changed. An ended call is reported once and then forgotten.
    fn on_call(&self, call: CallInfo);
    /// One frame of the other side's audio to play.
    fn on_playout(&self, samples: Vec<i16>);
}

/// Places, answers and ends calls.
#[derive(uniffi::Object)]
pub struct CallCenter {
    center: Arc<Center>,
}

static SHARED: OnceLock<Arc<CallCenter>> = OnceLock::new();

/// Makes the call center and hands it the worker's clients. Runs before the
/// backend starts, so the first client is not missed.
pub(crate) fn install() -> Arc<CallCenter> {
    SHARED
        .get_or_init(|| {
            let center = Center::new();
            let hooked = center.clone();
            if !zapfast::backend::set_client_hook(Box::new(move |client| hooked.link(client))) {
                log::warn!("calls: another client hook is installed; calls are off");
            }
            Arc::new(CallCenter { center })
        })
        .clone()
}

#[uniffi::export]
impl CallCenter {
    /// The process's call center.
    #[uniffi::constructor]
    pub fn shared() -> Arc<Self> {
        install()
    }

    pub fn set_listener(&self, listener: Arc<dyn CallListener>) {
        self.center.set_listener(listener);
    }

    /// Calls a person's chat. `false` when it cannot start now: another call
    /// is going, the link is down, or the chat is not a person's.
    pub fn place(&self, chat: String) -> bool {
        self.center.place(chat)
    }

    /// Answers the ringing call, with audio only.
    pub fn answer(&self) {
        self.center.answer();
    }

    /// Declines a ringing call, or ends the call that is going.
    pub fn hang_up(&self) {
        self.center.hang_up();
    }

    pub fn set_muted(&self, muted: bool) {
        self.center.set_muted(muted);
    }

    /// One frame of microphone audio, [`FRAME_SAMPLES`] long.
    pub fn push_microphone(&self, samples: Vec<i16>) {
        self.center.push_microphone(samples);
    }

    /// The call going now, if any.
    pub fn current(&self) -> Option<CallInfo> {
        self.center.current()
    }
}

/// Samples in one call audio frame, for Swift.
#[uniffi::export]
pub fn call_frame_samples() -> u32 {
    FRAME_SAMPLES
}
