//! Cutting short the wait before WhatsApp is dialled again.
//!
//! After a connection fails, whatsapp-rust waits before the next try, longer
//! each time, up to fifteen minutes (WhatsApp Web's own schedule). That suits
//! a service that is down, not a Mac whose Wi-Fi was off for a minute: when
//! the network comes back, nothing tells the library, and the link can sit
//! idle for a quarter of an hour with a good connection under it.
//!
//! The library's own way to say "go now" is `pause` followed by `resume`: its
//! supervision loop races the backoff against pauses, and a resume reconnects
//! at once with no backoff owed. Swift knows when the network returned, so it
//! asks through [`skip_wait`].
//!
//! The worker hands each new client to the single hook upstream allows (the
//! call center installs it), which passes it on to [`made`].

use std::sync::{Arc, Mutex, MutexGuard, Weak};

use whatsapp_rust::Client;

/// The worker's current client and the runtime it lives on.
struct Current {
    client: Weak<Client>,
    runtime: tokio::runtime::Handle,
}

static CURRENT: Mutex<Option<Current>> = Mutex::new(None);

fn current() -> MutexGuard<'static, Option<Current>> {
    CURRENT.lock().unwrap_or_else(|p| p.into_inner())
}

/// Remembers the worker's new client. Called on the worker's runtime.
pub(crate) fn made(client: &Arc<Client>) {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        log::warn!("link: the client arrived outside its runtime; reconnecting on request is off");
        return;
    };
    *current() = Some(Current {
        client: Arc::downgrade(client),
        runtime,
    });
}

/// Reconnects now instead of at the end of the library's wait, if there is a
/// client. Returns whether one was asked to.
///
/// Meant for a link that is down: on a healthy one it only costs a quick
/// reconnect, since the connection is torn down and made again.
pub(crate) fn skip_wait() -> bool {
    let (client, runtime) = {
        let current = current();
        let Some(current) = current.as_ref() else {
            return false;
        };
        let Some(client) = current.client.upgrade() else {
            return false;
        };
        (client, current.runtime.clone())
    };
    log::info!("link: reconnecting without waiting");
    runtime.spawn(async move {
        client.pause().await;
        client.resume();
    });
    true
}
