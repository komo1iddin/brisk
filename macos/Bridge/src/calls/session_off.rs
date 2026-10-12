//! The call center of a build without the `calls` feature: the VoIP stack is
//! not linked, so nothing rings, nothing is placed, and no history is kept.
//! It answers the same calls as `session`'s, so Swift's side is the same in
//! both builds and asks `calls_supported` whether to show any of it.

use std::sync::Arc;

use super::history::CallLogEntry;
use super::{CallInfo, CallListener};

pub(crate) struct Center;

impl Center {
    pub fn new() -> Arc<Self> {
        Arc::new(Self)
    }

    pub fn history(&self, _chat: &str) -> Vec<CallLogEntry> {
        Vec::new()
    }

    pub fn set_listener(&self, _listener: Arc<dyn CallListener>) {}

    pub fn current(&self) -> Vec<CallInfo> {
        Vec::new()
    }

    pub fn place(self: &Arc<Self>, _chat: String, _video: bool) -> bool {
        false
    }

    pub fn answer(self: &Arc<Self>, _id: u64, _video: bool) {}

    pub fn end(self: &Arc<Self>, _id: u64) {}

    pub fn set_muted(self: &Arc<Self>, _muted: bool) {}

    pub fn set_camera(self: &Arc<Self>, _on: bool) {}

    pub fn push_video(&self, _data: Vec<u8>, _timestamp: u32) {}

    pub fn request_keyframe(&self) {}

    pub fn push_microphone(&self, _samples: Vec<i16>) {}
}
