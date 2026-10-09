//! The WhatsApp accounts on this Mac, kept as upstream keeps them.
//!
//! Upstream links several accounts in one process: a roster
//! (`Config/accounts.json`, [`AccountRoster`]) names them, and each has its
//! own folders, `State/accounts/<id>` and `<caches>/accounts/<id>`, with its
//! session, archive (and that archive's keyring key), media and avatars. A
//! single-account setup left at the top of `State` moves into account 1 on
//! the first start, by upstream's [`AppDirs::adopt_single_account`], which
//! refuses when anything is in the way and copies the archive's key before
//! moving the archive. The call history, which only this app keeps, moves
//! beside it.
//!
//! The manager is opened once per process and holds the data folder's lock.
//! Each account's [`BridgeClient`] runs one upstream backend.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use zapfast::model::AccountId;
use zapfast::paths::{AccountDirs, AppDirs};
use zapfast::settings::AccountRoster;

use crate::client::{BridgeClient, BridgeConfig, BridgeError};

/// The accounts, in the order the switcher shows them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountList {
    /// The account on screen.
    pub active: String,
    pub order: Vec<String>,
}

#[derive(uniffi::Object)]
pub struct AccountManager {
    dirs: AppDirs,
    roster: Mutex<AccountRoster>,
    /// Held while the app runs, so a second copy cannot open the same data.
    _instance: std::fs::File,
}

#[uniffi::export]
impl AccountManager {
    /// Prepares the data folder, starts logging, moves a single-account setup
    /// into account 1, and reads the roster. Fails rather than start empty
    /// when the old setup cannot be moved.
    #[uniffi::constructor]
    pub fn open(config: BridgeConfig) -> Result<Arc<Self>, BridgeError> {
        let dirs = app_dirs(&config);
        dirs.ensure().map_err(storage)?;
        let instance = lock_instance(&dirs)?;
        crate::logging::init(&dirs, config.verbose);
        // Before any backend makes its client, so calls see the first one.
        crate::calls::install();
        adopt_single_account(&dirs)?;
        let roster = AccountRoster::load(&dirs.accounts_file()).map_err(storage)?;
        roster.save(&dirs.accounts_file()).map_err(storage)?;
        log::info!("accounts: {} on this Mac", roster.order.len());
        Ok(Arc::new(Self {
            dirs,
            roster: Mutex::new(roster),
            _instance: instance,
        }))
    }

    pub fn accounts(&self) -> AccountList {
        let roster = self.roster();
        AccountList {
            active: roster.active.clone(),
            order: roster.order.clone(),
        }
    }

    /// Puts `id` on screen at the next start too.
    pub fn set_active(&self, id: String) -> Result<(), BridgeError> {
        let mut roster = self.roster();
        if !roster.order.contains(&id) || roster.active == id {
            return Ok(());
        }
        roster.active = id;
        roster.save(&self.dirs.accounts_file()).map_err(storage)
    }

    /// A new account, listed last and made the active one; its client links
    /// it with a QR code like the first.
    pub fn add(&self) -> Result<String, BridgeError> {
        let mut roster = self.roster();
        let id = roster.allocate();
        roster.save(&self.dirs.accounts_file()).map_err(storage)?;
        log::info!("accounts: added one");
        Ok(id.0)
    }

    /// The client of account `id`, not started yet.
    pub fn client(&self, id: String) -> Result<Arc<BridgeClient>, BridgeError> {
        let dirs = self.account_dirs(&id)?;
        dirs.ensure().map_err(storage)?;
        Ok(BridgeClient::new(dirs))
    }

    /// Deletes a removed account's folders, then its archive key, and drops
    /// it from the roster. Call it once its client has stopped: after the
    /// backend reported `AccountRemoved` and the client was shut down. The
    /// last account is never removed, only unlinked.
    pub fn remove_files(&self, id: String) -> Result<(), BridgeError> {
        let dirs = self.account_dirs(&id)?;
        {
            let roster = self.roster();
            if roster.order.len() <= 1 {
                return Err(BridgeError::Storage {
                    message: "The last account stays; unlink it instead".into(),
                });
            }
        }
        let result = delete_account_files(&dirs);
        crate::calls::forget(&id);
        let mut roster = self.roster();
        roster.order.retain(|listed| listed != &id);
        roster.sanitize();
        roster.save(&self.dirs.accounts_file()).map_err(storage)?;
        log::info!("accounts: removed one");
        result
    }

    /// Where account `id` keeps downloads unless a folder was chosen.
    pub fn media_folder(&self, id: String) -> Result<String, BridgeError> {
        let dirs = self.account_dirs(&id)?;
        Ok(dirs.media_cache_dir().to_string_lossy().into_owned())
    }
}

/// The account a start will put on screen, read from the roster without
/// opening anything: the app needs it before the manager opens.
#[uniffi::export]
pub fn peek_active_account(config: BridgeConfig) -> String {
    let dirs = app_dirs(&config);
    AccountRoster::load(&dirs.accounts_file())
        .map(|roster| roster.active)
        .unwrap_or_else(|_| AccountId::first().0)
}

impl AccountManager {
    fn roster(&self) -> std::sync::MutexGuard<'_, AccountRoster> {
        self.roster.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn account_dirs(&self, id: &str) -> Result<AccountDirs, BridgeError> {
        let account =
            AccountId::parse(id).filter(|_| self.roster().order.iter().any(|listed| listed == id));
        account
            .map(|account| self.dirs.account(&account))
            .ok_or_else(|| BridgeError::Storage {
                message: "There is no such account".into(),
            })
    }
}

fn storage(error: std::io::Error) -> BridgeError {
    BridgeError::Storage {
        message: error.to_string(),
    }
}

/// Upstream's move into account 1, then the call history this app keeps.
fn adopt_single_account(dirs: &AppDirs) -> Result<(), BridgeError> {
    dirs.adopt_single_account().map_err(storage)?;
    let account = dirs.account(&AccountId::first());
    // Side files first: a database moved without its journal would lose the
    // calls still in it.
    for name in [
        "calls.db-wal",
        "calls.db-shm",
        "calls.db-journal",
        "calls.db",
    ] {
        move_if_free(&dirs.state.join(name), &account.state.join(name)).map_err(storage)?;
    }
    Ok(())
}

/// Moves `from` to `to` unless `from` is missing; refuses to overwrite.
fn move_if_free(from: &Path, to: &Path) -> std::io::Result<()> {
    if !from.exists() {
        return Ok(());
    }
    if to.exists() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!(
                "{} is in the way of {}; nothing more was moved",
                to.display(),
                from.display()
            ),
        ));
    }
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::rename(from, to)
}

/// As upstream's `finish_removed`: the folders go first, and the archive's
/// key only once the archive is gone, never before.
fn delete_account_files(dirs: &AccountDirs) -> Result<(), BridgeError> {
    let key = zapfast::archive::archive_key_identity(&dirs.archive_db()).ok();
    let state = std::fs::remove_dir_all(&dirs.state).err();
    let cache = std::fs::remove_dir_all(&dirs.cache)
        .err()
        .filter(|error| error.kind() != std::io::ErrorKind::NotFound);
    if let Some(identity) = key
        && !dirs.archive_db().exists()
        && cfg!(not(test))
        && let Err(error) = zapfast::archive::forget_archive_key(&identity)
    {
        log::warn!("accounts: could not delete a removed account's archive key: {error:#}");
    }
    match state.or(cache) {
        Some(error) => Err(BridgeError::Storage {
            message: format!("Could not delete the removed account's files: {error}"),
        }),
        None => Ok(()),
    }
}

/// An exclusive lock on this data folder. Upstream's single-instance guard
/// also answers legacy FastsApp sockets, which upstream ZapFast itself may
/// hold, so the bridge keeps its own lock beside its own data.
pub(crate) fn lock_instance(dirs: &AppDirs) -> Result<std::fs::File, BridgeError> {
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

pub(crate) fn app_dirs(config: &BridgeConfig) -> AppDirs {
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

    fn root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "zapfast-bridge-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&root).ok();
        root
    }

    fn dirs_in(root: &Path) -> AppDirs {
        app_dirs(&BridgeConfig {
            data_dir: root.join("Data").to_string_lossy().into_owned(),
            cache_dir: root.join("Caches").to_string_lossy().into_owned(),
            verbose: false,
        })
    }

    #[test]
    fn first_launch_creates_the_runtime_folder_and_locks_it() {
        let root = root("lock");
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

    #[test]
    fn the_call_history_moves_into_account_one_and_never_over_another() {
        let root = root("calls");
        let dirs = dirs_in(&root);
        dirs.ensure().unwrap();
        std::fs::write(dirs.state.join("calls.db"), b"calls").unwrap();
        std::fs::write(dirs.state.join("calls.db-wal"), b"wal").unwrap();

        adopt_single_account(&dirs).unwrap();

        let account = dirs.account(&AccountId::first());
        assert_eq!(
            std::fs::read(account.state.join("calls.db")).unwrap(),
            b"calls"
        );
        assert_eq!(
            std::fs::read(account.state.join("calls.db-wal")).unwrap(),
            b"wal"
        );
        assert!(!dirs.state.join("calls.db").exists());

        // A second old history is left where it is, not written over the first.
        std::fs::write(dirs.state.join("calls.db"), b"other").unwrap();
        assert!(adopt_single_account(&dirs).is_err());
        assert_eq!(
            std::fs::read(account.state.join("calls.db")).unwrap(),
            b"calls"
        );
        assert!(dirs.state.join("calls.db").exists());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn accounts_are_added_switched_and_removed_but_never_the_last() {
        let root = root("roster");
        let config = BridgeConfig {
            data_dir: root.join("Data").to_string_lossy().into_owned(),
            cache_dir: root.join("Caches").to_string_lossy().into_owned(),
            verbose: false,
        };
        let manager = AccountManager::open(config.clone()).unwrap();
        assert_eq!(
            manager.accounts(),
            AccountList {
                active: "1".into(),
                order: vec!["1".into()]
            }
        );
        assert!(
            manager.remove_files("1".into()).is_err(),
            "the last one stays"
        );

        let added = manager.add().unwrap();
        assert_eq!(added, "2");
        assert_eq!(manager.accounts().active, "2");
        let dirs = dirs_in(&root).account(&AccountId(added.clone()));
        manager.client(added.clone()).unwrap();
        assert!(dirs.state.is_dir() && dirs.cache.is_dir());
        assert!(
            manager
                .media_folder(added.clone())
                .unwrap()
                .ends_with("accounts/2/media")
        );

        manager.set_active("1".into()).unwrap();
        assert!(manager.client("7".into()).is_err(), "not listed");
        assert!(manager.client("../1".into()).is_err(), "not a folder name");

        manager.remove_files(added).unwrap();
        assert!(!dirs.state.exists() && !dirs.cache.exists());
        assert_eq!(manager.accounts().order, vec!["1".to_owned()]);

        // The roster outlives the process.
        drop(manager);
        let again = AccountManager::open(config).unwrap();
        assert_eq!(again.accounts().order, vec!["1".to_owned()]);
        assert_eq!(again.add().unwrap(), "3", "an id is never given twice");
        std::fs::remove_dir_all(&root).ok();
    }
}
