//! The object Swift holds: starts the backend, sends commands, shuts down.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use zapfast::backend::Backend;
use zapfast::paths::AppDirs;

use crate::commands::BridgeCommand;
use crate::events::BridgeEvent;
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
    #[error("Could not prepare the app's folders: {message}")]
    Storage { message: String },
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

#[derive(uniffi::Object)]
pub struct BridgeClient {
    running: Mutex<Option<Running>>,
}

#[uniffi::export]
impl BridgeClient {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            running: Mutex::new(None),
        })
    }

    /// Opens the archive and connects. Events start flowing to `listener`.
    pub fn start(
        &self,
        config: BridgeConfig,
        listener: Arc<dyn EventListener>,
    ) -> Result<(), BridgeError> {
        let mut running = self.running.lock().unwrap_or_else(|p| p.into_inner());
        if running.is_some() {
            return Err(BridgeError::AlreadyRunning);
        }

        let dirs = app_dirs(&config);
        dirs.ensure().map_err(|error| BridgeError::Storage {
            message: error.to_string(),
        })?;
        crate::logging::init(&dirs, config.verbose);

        let (waker, signal) = crate::pump::waker();
        let mut backend = Backend::spawn(dirs, waker);
        // Upstream waits for its first window frame before touching storage;
        // our window is Swift's, which is already up when it calls start.
        if let Some(startup) = backend.take_startup() {
            let _ = startup.send(());
        }
        let backend = Arc::new(Mutex::new(backend));
        let pump = Pump::spawn(backend.clone(), signal, listener);
        log::info!("bridge started");

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
            backend
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .shutdown();
            log::info!("bridge stopped");
        }
    }
}

impl Drop for BridgeClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn app_dirs(config: &BridgeConfig) -> AppDirs {
    let data = PathBuf::from(&config.data_dir);
    AppDirs {
        config: data.join("Config"),
        state: data.join("State"),
        cache: PathBuf::from(&config.cache_dir),
        runtime: data.join("Runtime"),
    }
}
