//! The object Swift holds: starts the backend, sends commands, shuts down.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use zapfast::archive::Archive;
use zapfast::backend::Backend;
use zapfast::paths::AppDirs;

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
    /// Where the archive lives, for readers that open their own connection.
    archive: PathBuf,
    backend: Arc<Mutex<Backend>>,
    pump: Pump,
    /// Held while running, so a second copy cannot open the same archive.
    _instance: std::fs::File,
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
        let instance = lock_instance(&dirs)?;
        crate::logging::init(&dirs, config.verbose);

        // Before the backend makes its client, so calls see the first one.
        crate::calls::install();
        crate::calls::open_log(&dirs.state);
        let (waker, signal) = crate::pump::waker();
        let archive = dirs.archive_db();
        // One account, kept where the app has always kept it: upstream's account
        // folders are for its several-accounts window, which this app has not.
        let mut backend = Backend::spawn(dirs.as_account(), waker);
        // Upstream waits for its first window frame before touching storage;
        // our window is Swift's, which is already up when it calls start.
        if let Some(startup) = backend.take_startup() {
            let _ = startup.send(());
        }
        let backend = Arc::new(Mutex::new(backend));
        let pump = Pump::spawn(backend.clone(), signal, listener);
        log::info!("bridge started");

        *running = Some(Running {
            archive,
            backend,
            pump,
            _instance: instance,
        });
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
        crate::link::skip_wait()
    }

    /// Opens a reader on the archive for exporting one chat. It has a
    /// connection of its own, so reading does not wait for the worker or
    /// change what the open timeline shows. Does blocking work: call it off
    /// the main thread.
    pub fn open_chat_reader(&self) -> Result<Arc<ChatReader>, BridgeError> {
        let path = {
            let running = self.running.lock().unwrap_or_else(|p| p.into_inner());
            running
                .as_ref()
                .map(|running| running.archive.clone())
                .ok_or(BridgeError::NotRunning)?
        };
        let archive = Archive::open(&path).map_err(|error| BridgeError::Archive {
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
        if let Some(Running { backend, pump, .. }) = running {
            pump.stop();
            backend.lock().unwrap_or_else(|p| p.into_inner()).shutdown();
            log::info!("bridge stopped");
        }
    }
}

impl Drop for BridgeClient {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// An exclusive lock on this data folder. Upstream's single-instance guard
/// also answers legacy FastsApp sockets, which upstream ZapFast itself may
/// hold, so the bridge keeps its own lock beside its own data.
fn lock_instance(dirs: &AppDirs) -> Result<std::fs::File, BridgeError> {
    let storage = |error: std::io::Error| BridgeError::Storage {
        message: error.to_string(),
    };
    // Upstream's `AppDirs::ensure` leaves the runtime folder to its own
    // single-instance guard, which the bridge does not use.
    let mut folder = std::fs::DirBuilder::new();
    folder.recursive(true);
    {
        use std::os::unix::fs::DirBuilderExt;
        folder.mode(0o700);
    }
    folder.create(&dirs.runtime).map_err(storage)?;
    let path = dirs.runtime.join("instance.lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(storage)?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(std::fs::TryLockError::WouldBlock) => Err(BridgeError::AnotherInstance),
        Err(std::fs::TryLockError::Error(error)) => Err(storage(error)),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn dirs_in(root: &std::path::Path) -> AppDirs {
        app_dirs(&BridgeConfig {
            data_dir: root.join("Data").to_string_lossy().into_owned(),
            cache_dir: root.join("Caches").to_string_lossy().into_owned(),
            verbose: false,
        })
    }

    #[test]
    fn first_launch_creates_the_runtime_folder_and_locks_it() {
        let root = std::env::temp_dir().join(format!("zapfast-bridge-lock-{}", std::process::id()));
        std::fs::remove_dir_all(&root).ok();
        let dirs = dirs_in(&root);
        dirs.ensure().unwrap();
        assert!(
            !dirs.runtime.exists(),
            "upstream's ensure() does not create it"
        );

        let held = lock_instance(&dirs).expect("a fresh profile can be locked");
        assert!(matches!(
            lock_instance(&dirs),
            Err(BridgeError::AnotherInstance)
        ));

        drop(held);
        assert!(
            lock_instance(&dirs).is_ok(),
            "the lock is released with its file"
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
