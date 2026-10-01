//! Hands the WhatsApp client to an embedder each time the worker makes one.
//!
//! The client is otherwise private to the worker. An embedder that drives a
//! feature this interface does not (the native macOS app places and answers
//! calls) installs a hook once, before [`super::Backend::spawn`].

use std::sync::{Arc, OnceLock};

use whatsapp_rust::Client;

/// Receives each new client on the worker's runtime, so it may spawn there.
pub type ClientHook = Box<dyn Fn(Arc<Client>) + Send + Sync>;

static HOOK: OnceLock<ClientHook> = OnceLock::new();

/// Installs the hook for this process. Returns `false` if one already was.
pub fn set_client_hook(hook: ClientHook) -> bool {
    HOOK.set(hook).is_ok()
}

pub(super) fn client_made(client: &Arc<Client>) {
    if let Some(hook) = HOOK.get() {
        hook(client.clone());
    }
}
