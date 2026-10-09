//! One account's backend as Swift holds it: starts it, sends commands, shuts
//! it down. [`crate::accounts::AccountManager`] makes one per account.

use std::sync::{Arc, Mutex};

use zapfast::archive::Archive;
use zapfast::backend::Backend;
use zapfast::paths::AccountDirs;

use crate::commands::BridgeCommand;
use crate::events::BridgeEvent;
use crate::export::ChatReader;
use crate::pump::Pump;

/// Where the app keeps its files. Swift passes sandbox-aware locations, so
/// the bridge never guesses and never shares upstream ZapFast's directories.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BridgeConfig {
    /// Application Support folder for this app: settings, session, archive.
    pub data_dir: String,
    /// Caches folder for this app: media, avatars, stickers.
    pub cache_dir: String,
    /// Debug-level logging for ZapFast and the WhatsApp library.
    pub verbose: bool,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("The backend is already running")]
    AlreadyRunning,
    /// Another copy of the app holds this data folder.
    #[error("ZapFast is already running")]
    AnotherInstance,
    #[error("Could not prepare the app's folders: {message}")]
    Storage { message: String },
    #[error("Could not read the recording: {message}")]
    Media { message: String },
    /// The archive could not be opened or read.
    #[error("Could not read the chat archive: {message}")]
    Archive { message: String },
    /// Asked before `start`, or after `shutdown`.
    #[error("The backend is not running")]
    NotRunning,
}

/// Receives backend events on a background thread, in the order they
/// happened. Implementations hop to the main actor themselves.
#[uniffi::export(with_foreign)]
pub trait EventListener: Send + Sync {
    fn on_events(&self, events: Vec<BridgeEvent>);
}

struct Running {
    backend: Arc<Mutex<Backend>>,
    pump: Pump,
}

/// One account's backend: the object Swift holds per account.
#[derive(uniffi::Object)]
pub struct BridgeClient {
    dirs: AccountDirs,
    running: Mutex<Option<Running>>,
}

impl BridgeClient {
    pub(crate) fn new(dirs: AccountDirs) -> Arc<Self> {
        Arc::new(Self {
            dirs,
            running: Mutex::new(None),
        })
    }
}

#[uniffi::export]
impl BridgeClient {
    /// The account this client runs.
    pub fn account(&self) -> String {
        self.dirs.id.0.clone()
    }

    /// Opens the account's archive and connects. Events start flowing to
    /// `listener`.
    pub fn start(&self, listener: Arc<dyn EventListener>) -> Result<(), BridgeError> {
        let mut running = self.running.lock().unwrap_or_else(|p| p.into_inner());
        if running.is_some() {
            return Err(BridgeError::AlreadyRunning);
        }
        crate::calls::open_log(self.dirs.id.as_str(), &self.dirs.state);
        let (waker, signal) = crate::pump::waker();
        let mut backend = Backend::spawn(self.dirs.clone(), waker);
        // Upstream waits for its first window frame before touching storage;
        // our window is Swift's, which is already up when it calls start.
        if let Some(startup) = backend.take_startup() {
            let _ = startup.send(());
        }
        let backend = Arc::new(Mutex::new(backend));
        let pump = Pump::spawn(backend.clone(), signal, listener);
        log::info!("bridge started an account");

        *running = Some(Running { backend, pump });
        Ok(())
    }

    /// Queues a command for the backend. Ignored before `start`.
    pub fn send(&self, command: BridgeCommand) {
        let running = self.running.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(running) = running.as_ref() {
            let command = command.into_upstream();
            running
                .backend
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .send(command);
        }
    }

    /// Reconnects to WhatsApp now, without waiting out the library's delay
    /// between tries (up to fifteen minutes after repeated failures). For a
    /// link that is down when the network comes back; Swift calls it then.
    /// Returns `false` when there is no client to ask yet.
    pub fn reconnect_now(&self) -> bool {
        crate::link::skip_wait(self.dirs.id.as_str())
    }

    /// Opens a reader on the archive for exporting one chat. It has a
    /// connection of its own, so reading does not wait for the worker or
    /// change what the open timeline shows. Does blocking work: call it off
    /// the main thread.
    pub fn open_chat_reader(&self) -> Result<Arc<ChatReader>, BridgeError> {
        if self
            .running
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .is_none()
        {
            return Err(BridgeError::NotRunning);
        }
        let archive =
            Archive::open(&self.dirs.archive_db()).map_err(|error| BridgeError::Archive {
                message: error.to_string(),
            })?;
        Ok(Arc::new(ChatReader::new(archive)))
    }

    /// Flushes and closes the archive and the connection. Blocks for up to a
    /// few seconds while the runtime winds down.
    pub fn shutdown(&self) {
        let running = self
            .running
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take();
        if let Some(Running { backend, pump }) = running {
            pump.stop();
            backend.lock().unwrap_or_else(|p| p.into_inner()).shutdown();
            log::info!("bridge stopped an account");
        }
    }
}

impl Drop for BridgeClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}
