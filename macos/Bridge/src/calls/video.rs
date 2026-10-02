//! A call's video, as the library carries it: H.264 access units in Annex-B
//! form, never pixels. Swift captures and encodes (VideoToolbox, Constrained
//! Baseline with the parameter sets before each keyframe, as WhatsApp sends)
//! and decodes what arrives; the bridge only passes the units along.

use whatsapp_rust::async_channel;
use whatsapp_rust::voip::{TimedVideoFrame, VideoFrame, VideoSource};

/// Frames per second Swift encodes at, and so the RTP clock's step.
pub const FRAME_RATE: u32 = 20;
/// Encoded frames that may wait for the engine; a late frame is worse than
/// a dropped one.
const CAMERA_QUEUE: usize = 4;
/// Received frames that may wait for Swift.
pub const VIEW_QUEUE: usize = 8;

/// One access unit from the other side.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VideoFrameInfo {
    /// Annex-B H.264, start codes included.
    pub data: Vec<u8>,
    /// Carries a keyframe (and its parameter sets): a decoder may start here.
    pub keyframe: bool,
    /// The sender's rotation, in quarter turns clockwise.
    pub orientation: u8,
}

impl From<VideoFrame> for VideoFrameInfo {
    fn from(frame: VideoFrame) -> Self {
        Self {
            data: frame.data,
            keyframe: frame.keyframe,
            orientation: frame.orientation & 0x03,
        }
    }
}

/// Our camera, as the library reads it: units with their capture times.
pub struct Camera {
    timed: async_channel::Receiver<TimedVideoFrame>,
    /// The untimed path the trait also asks for; nothing is ever sent on it.
    untimed: async_channel::Receiver<Vec<u8>>,
    _untimed_sender: async_channel::Sender<Vec<u8>>,
}

impl Camera {
    /// The camera, and where Swift's encoded units go into it.
    pub fn new() -> (Self, async_channel::Sender<TimedVideoFrame>) {
        let (sender, timed) = async_channel::bounded(CAMERA_QUEUE);
        let (untimed_sender, untimed) = async_channel::bounded(1);
        (
            Self {
                timed,
                untimed,
                _untimed_sender: untimed_sender,
            },
            sender,
        )
    }
}

impl VideoSource for Camera {
    fn frames(&self) -> async_channel::Receiver<Vec<u8>> {
        self.untimed.clone()
    }

    fn timed_frames(&self) -> Option<async_channel::Receiver<TimedVideoFrame>> {
        Some(self.timed.clone())
    }

    fn rtp_timestamp_stride(&self) -> u32 {
        90_000 / FRAME_RATE
    }
}

/// A unit Swift encoded, captured at `timestamp` on the 90 kHz clock.
pub fn timed(data: Vec<u8>, timestamp: u32) -> TimedVideoFrame {
    TimedVideoFrame::builder()
        .data(data)
        .timestamp(timestamp)
        .build()
}
