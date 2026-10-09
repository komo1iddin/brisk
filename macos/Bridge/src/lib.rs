//! Swift-facing bridge over ZapFast's backend.
//!
//! Upstream's interface talks to its tokio runtime only through
//! `zapfast::backend::{Command, Event}`. This crate keeps that seam and exposes
//! it to Swift through UniFFI:
//!
//! - [`types`] mirrors the upstream model as FFI records and enums;
//! - [`commands`] turns Swift's [`BridgeCommand`] into upstream commands;
//! - [`events`] turns upstream events into [`BridgeEvent`]s, matching every
//!   variant so a new upstream event fails the build instead of vanishing;
//! - [`pump`] delivers events to Swift when the backend wakes its "window";
//! - [`accounts`] keeps the accounts and opens the data folder once;
//! - [`client`] is the object Swift holds for each account.
//!
//! Nothing here reimplements protocol or storage behaviour. When the bridge
//! needs something upstream does not expose, propose it upstream.

uniffi::setup_scaffolding!();

mod accounts;
mod calls;
mod client;
mod commands;
mod events;
mod export;
mod helpers;
mod link;
mod logging;
mod pump;
mod themes;
pub mod types;
mod vcard;

pub use accounts::{AccountList, AccountManager, peek_active_account};
pub use calls::{
    CallCenter, CallEndReason, CallInfo, CallListener, CallLogEntry, CallOutcome, CallParticipant,
    CallPhase, VideoFrameInfo,
};
pub use client::{BridgeClient, BridgeConfig, BridgeError, EventListener};
pub use commands::BridgeCommand;
pub use events::BridgeEvent;
pub use export::{ChatCensus, ChatMedia, ChatMediaKind, ChatReader};
pub use themes::{PaletteTheme, palette_presets, palette_themes_in};
