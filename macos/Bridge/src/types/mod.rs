//! FFI mirrors of upstream types.
//!
//! Each upstream type gets a record or enum here plus a `From` conversion.
//! Conversions destructure upstream structs field by field (no `..`), so a
//! field added or renamed upstream is a compile error in the bridge rather
//! than data silently dropped on the way to Swift.

mod chat;
mod contact;
mod link;
mod message;

pub use chat::{ChatKind, ChatPreview, ChatSummary, DeliveryState};
pub use contact::ContactRecord;
pub use link::LinkState;
pub use message::{
    LinkPreviewInfo, MediaInfo, MentionInfo, MessageContent, MessageRecord, OnceMediaKind, PageKey,
    PollSummary, QuotedMessage, ReactionInfo,
};

pub(crate) fn path_string(path: std::path::PathBuf) -> String {
    path.to_string_lossy().into_owned()
}

pub(crate) fn count(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}
