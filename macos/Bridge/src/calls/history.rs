//! Call history, kept for the chats' timelines.
//!
//! Upstream keeps no calls, so the bridge has a small store of its own beside
//! upstream's archive, encrypted the same way: SQLCipher with a random key in
//! the OS keyring. It holds the calls the phone syncs through app state
//! (`call_log`, read by whatsapp-rust as `Event::CallLogSync`) and the calls
//! this app rang or placed. The phone's record of a call replaces ours.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result, ensure};
use keyring_core::api::CredentialStoreApi;
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use whatsapp_rust::waproto::whatsapp::CallLogRecord;
use whatsapp_rust::waproto::whatsapp::call_log_record::CallResult;
use zeroize::Zeroizing;

use super::CallEndReason;

/// How a call went, worded from this account's side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CallOutcome {
    /// Both sides talked; the entry's duration says how long.
    Connected,
    /// Someone called and nobody here answered.
    Missed,
    /// The called side declined.
    Declined,
    /// Nobody answered our call.
    NoAnswer,
    /// We gave up before it was answered.
    Cancelled,
    AnsweredElsewhere,
    Failed,
}

impl CallOutcome {
    fn key(self) -> &'static str {
        match self {
            Self::Connected => "connected",
            Self::Missed => "missed",
            Self::Declined => "declined",
            Self::NoAnswer => "no_answer",
            Self::Cancelled => "cancelled",
            Self::AnsweredElsewhere => "answered_elsewhere",
            Self::Failed => "failed",
        }
    }

    fn from_key(key: &str) -> Option<Self> {
        Some(match key {
            "connected" => Self::Connected,
            "missed" => Self::Missed,
            "declined" => Self::Declined,
            "no_answer" => Self::NoAnswer,
            "cancelled" => Self::Cancelled,
            "answered_elsewhere" => Self::AnsweredElsewhere,
            "failed" => Self::Failed,
            _ => return None,
        })
    }
}

/// One call in a chat's history.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CallLogEntry {
    /// WhatsApp's id for the call.
    pub call_id: String,
    /// The chat it belongs to: the other person's, or the group's.
    pub chat: String,
    pub from_me: bool,
    pub video: bool,
    pub outcome: CallOutcome,
    /// When it started, in Unix seconds.
    pub timestamp: i64,
    /// Seconds talked; zero unless connected.
    pub duration: u32,
}

/// Where an entry came from: the phone's record wins over ours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Phone,
    Here,
}

pub struct CallLog {
    connection: Mutex<Connection>,
}

impl CallLog {
    /// Opens (or makes) the store at `path`, with its key from the keyring.
    pub fn open(path: &Path) -> Result<Self> {
        let key = key_for(path)?;
        Self::open_with_key(path, &key)
    }

    fn open_with_key(path: &Path, key: &[u8; 32]) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        if !path.exists() {
            private_file(path)?;
        }
        let connection = Connection::open(path)?;
        connection.pragma_update(None, "key", &*key_literal(key))?;
        // A key alone is not checked until a page is read.
        connection
            .query_row("SELECT count(*) FROM sqlite_master", [], |row| {
                row.get::<_, i64>(0)
            })
            .context("The call history could not be unlocked with its keyring key")?;
        connection.execute_batch(
            "PRAGMA temp_store = MEMORY;
             CREATE TABLE IF NOT EXISTS calls (
                 call_id TEXT PRIMARY KEY,
                 chat TEXT NOT NULL,
                 from_me INTEGER NOT NULL,
                 video INTEGER NOT NULL,
                 outcome TEXT NOT NULL,
                 timestamp INTEGER NOT NULL,
                 duration INTEGER NOT NULL,
                 from_phone INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS calls_by_chat ON calls (chat, timestamp);",
        )?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    /// Files `entry`. Returns whether the history changed: an entry of ours
    /// never replaces the phone's.
    pub fn record(&self, entry: &CallLogEntry, source: Source) -> Result<bool> {
        let connection = self.connection.lock().unwrap_or_else(|p| p.into_inner());
        let existing: Option<(bool, String, i64, i64)> = connection
            .query_row(
                "SELECT from_phone, outcome, duration, timestamp FROM calls WHERE call_id = ?1",
                [&entry.call_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        if let Some((from_phone, outcome, duration, timestamp)) = &existing {
            if *from_phone && source == Source::Here {
                return Ok(false);
            }
            if outcome == entry.outcome.key()
                && *duration == i64::from(entry.duration)
                && *timestamp == entry.timestamp
            {
                return Ok(false);
            }
        }
        connection.execute(
            "INSERT OR REPLACE INTO calls
                 (call_id, chat, from_me, video, outcome, timestamp, duration, from_phone)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                entry.call_id,
                entry.chat,
                entry.from_me,
                entry.video,
                entry.outcome.key(),
                entry.timestamp,
                entry.duration,
                source == Source::Phone,
            ],
        )?;
        Ok(true)
    }

    /// The chat's calls, oldest first.
    pub fn chat(&self, chat: &str) -> Result<Vec<CallLogEntry>> {
        let connection = self.connection.lock().unwrap_or_else(|p| p.into_inner());
        let mut statement = connection.prepare_cached(
            "SELECT call_id, chat, from_me, video, outcome, timestamp, duration
             FROM calls WHERE chat = ?1 ORDER BY timestamp, call_id",
        )?;
        let rows = statement.query_map([chat], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, bool>(2)?,
                row.get::<_, bool>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
            ))
        })?;
        let mut entries = Vec::new();
        for row in rows {
            let (call_id, chat, from_me, video, outcome, timestamp, duration) = row?;
            let Some(outcome) = CallOutcome::from_key(&outcome) else {
                continue;
            };
            entries.push(CallLogEntry {
                call_id,
                chat,
                from_me,
                video,
                outcome,
                timestamp,
                duration: u32::try_from(duration).unwrap_or(0),
            });
        }
        Ok(entries)
    }
}

/// How a call this app rang or placed went, from how it ended.
pub fn here_outcome(incoming: bool, connected: bool, reason: &CallEndReason) -> CallOutcome {
    use CallEndReason as Why;
    if connected {
        return CallOutcome::Connected;
    }
    match (incoming, reason) {
        (_, Why::AnsweredElsewhere) => CallOutcome::AnsweredElsewhere,
        (_, Why::Failed { .. } | Why::ConnectionLost) => CallOutcome::Failed,
        // Declined here or elsewhere, or given up on: the phone files all
        // of them as missed.
        (true, _) => CallOutcome::Missed,
        (false, Why::PeerDeclined | Why::DeclinedElsewhere) => CallOutcome::Declined,
        (false, Why::HungUp | Why::Declined) => CallOutcome::Cancelled,
        (false, Why::NoAnswer | Why::Missed | Why::PeerHungUp) => CallOutcome::NoAnswer,
    }
}

/// How the phone's record reads from this side, or `None` for a call that is
/// not over (ongoing, upcoming) or says nothing usable.
pub fn outcome_of(record: &CallLogRecord, from_me: bool) -> Option<CallOutcome> {
    Some(match record.call_result? {
        CallResult::CONNECTED => CallOutcome::Connected,
        CallResult::REJECTED => CallOutcome::Declined,
        CallResult::CANCELLED if from_me => CallOutcome::Cancelled,
        CallResult::CANCELLED | CallResult::MISSED if !from_me => CallOutcome::Missed,
        CallResult::MISSED => CallOutcome::NoAnswer,
        CallResult::ACCEPTEDELSEWHERE => CallOutcome::AnsweredElsewhere,
        CallResult::INVALID
        | CallResult::UNAVAILABLE
        | CallResult::FAILED
        | CallResult::ABANDONED => CallOutcome::Failed,
        CallResult::UPCOMING | CallResult::ONGOING => return None,
        _ => return None,
    })
}

/// A record's start in Unix seconds: writers disagree on seconds and
/// milliseconds, and no call happened before 2001 in seconds or after 2286
/// in milliseconds.
pub fn seconds(start: i64) -> i64 {
    if start > 10_000_000_000 {
        start / 1000
    } else {
        start
    }
}

// Keyring and file, as upstream's archive does them (src/archive/encryption.rs,
// which is private to upstream's crate).

fn key_for(path: &Path) -> Result<Zeroizing<[u8; 32]>> {
    let parent = path.parent().context("The call history has no folder")?;
    fs::create_dir_all(parent)?;
    // A digest of the folder, never a user path, keeps profiles apart.
    let digest = Sha256::digest(parent.canonicalize()?.as_os_str().as_encoded_bytes());
    let identity = format!(
        "calls-{}",
        digest
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    );
    let store = apple_native_keyring_store::keychain::Store::new()
        .map_err(|e| anyhow::anyhow!("{e}"))
        .context("The keychain is not available")?;
    let entry = store
        .build("com.komoliddin.ZapFastMac", &identity, None)
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    match entry.get_secret() {
        Ok(secret) => {
            let secret = Zeroizing::new(secret);
            ensure!(secret.len() == 32, "The call history key is invalid");
            let mut key = Zeroizing::new([0; 32]);
            key.copy_from_slice(&secret);
            Ok(key)
        }
        Err(keyring_core::Error::NoEntry) => {
            // A store without its key can never be read again: start over.
            if path.exists() {
                fs::rename(path, aside(path))?;
            }
            let mut key = Zeroizing::new([0; 32]);
            getrandom::fill(key.as_mut()).context("Could not make a call history key")?;
            entry
                .set_secret(key.as_ref())
                .map_err(|e| anyhow::anyhow!("{e}"))?;
            Ok(key)
        }
        Err(error) => Err(anyhow::anyhow!("{error}")),
    }
}

fn aside(path: &Path) -> PathBuf {
    path.with_extension("db.unreadable")
}

fn key_literal(key: &[u8; 32]) -> Zeroizing<String> {
    use std::fmt::Write;
    let mut literal = Zeroizing::new(String::with_capacity(67));
    literal.push_str("x'");
    for byte in key {
        write!(&mut *literal, "{byte:02x}").expect("writing to a String");
    }
    literal.push('\'');
    literal
}

fn private_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?
        .sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (CallLog, PathBuf) {
        let folder = std::env::temp_dir().join(format!(
            "zapfast-call-log-{}-{}",
            std::process::id(),
            rand_suffix()
        ));
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join("calls.db");
        (CallLog::open_with_key(&path, &[7; 32]).unwrap(), folder)
    }

    fn rand_suffix() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }

    fn entry(id: &str, chat: &str, at: i64, outcome: CallOutcome) -> CallLogEntry {
        CallLogEntry {
            call_id: id.into(),
            chat: chat.into(),
            from_me: false,
            video: false,
            outcome,
            timestamp: at,
            duration: 0,
        }
    }

    #[test]
    fn a_chat_reads_its_own_calls_in_order() {
        let (log, folder) = store();
        log.record(&entry("b", "x", 20, CallOutcome::Missed), Source::Here)
            .unwrap();
        log.record(&entry("a", "x", 10, CallOutcome::Missed), Source::Here)
            .unwrap();
        log.record(&entry("c", "y", 15, CallOutcome::Missed), Source::Here)
            .unwrap();
        let ids: Vec<_> = log
            .chat("x")
            .unwrap()
            .into_iter()
            .map(|e| e.call_id)
            .collect();
        assert_eq!(ids, ["a", "b"]);
        fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn the_phones_record_wins_over_ours() {
        let (log, folder) = store();
        let ours = CallLogEntry {
            duration: 60,
            ..entry("a", "x", 10, CallOutcome::Connected)
        };
        assert!(log.record(&ours, Source::Here).unwrap());
        let phone = CallLogEntry {
            duration: 61,
            ..ours.clone()
        };
        assert!(log.record(&phone, Source::Phone).unwrap());
        assert!(!log.record(&ours, Source::Here).unwrap());
        assert_eq!(log.chat("x").unwrap()[0].duration, 61);
        assert!(
            !log.record(&phone, Source::Phone).unwrap(),
            "the same record changes nothing"
        );
        fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn the_store_is_encrypted() {
        let (log, folder) = store();
        log.record(&entry("a", "x", 10, CallOutcome::Missed), Source::Here)
            .unwrap();
        drop(log);
        let bytes = fs::read(folder.join("calls.db")).unwrap();
        assert!(!bytes.starts_with(b"SQLite format 3\0"));
        assert!(CallLog::open_with_key(&folder.join("calls.db"), &[8; 32]).is_err());
        fs::remove_dir_all(folder).ok();
    }

    #[test]
    fn the_phones_results_read_from_this_side() {
        let record = |result| CallLogRecord {
            call_result: Some(result),
            ..Default::default()
        };
        assert_eq!(
            outcome_of(&record(CallResult::MISSED), false),
            Some(CallOutcome::Missed)
        );
        assert_eq!(
            outcome_of(&record(CallResult::MISSED), true),
            Some(CallOutcome::NoAnswer)
        );
        assert_eq!(
            outcome_of(&record(CallResult::CANCELLED), true),
            Some(CallOutcome::Cancelled)
        );
        assert_eq!(
            outcome_of(&record(CallResult::CANCELLED), false),
            Some(CallOutcome::Missed)
        );
        assert_eq!(outcome_of(&record(CallResult::ONGOING), true), None);
        assert_eq!(outcome_of(&CallLogRecord::default(), true), None);
    }

    #[test]
    fn our_calls_read_as_the_phone_files_them() {
        use CallEndReason as Why;
        assert_eq!(
            here_outcome(true, true, &Why::PeerHungUp),
            CallOutcome::Connected
        );
        assert_eq!(
            here_outcome(true, false, &Why::Declined),
            CallOutcome::Missed
        );
        assert_eq!(here_outcome(true, false, &Why::Missed), CallOutcome::Missed);
        assert_eq!(
            here_outcome(false, false, &Why::PeerDeclined),
            CallOutcome::Declined
        );
        assert_eq!(
            here_outcome(false, false, &Why::HungUp),
            CallOutcome::Cancelled
        );
        assert_eq!(
            here_outcome(false, false, &Why::NoAnswer),
            CallOutcome::NoAnswer
        );
        assert_eq!(
            here_outcome(true, false, &Why::AnsweredElsewhere),
            CallOutcome::AnsweredElsewhere
        );
    }

    #[test]
    fn starts_in_milliseconds_become_seconds() {
        assert_eq!(seconds(1_700_000_000), 1_700_000_000);
        assert_eq!(seconds(1_700_000_000_123), 1_700_000_000);
    }
}
