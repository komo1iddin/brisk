//! Account privacy (upstream's `privacy.rs`). The values live on the phone;
//! `PrivacySnapshot` is upstream's own `Snapshot`, so optimistic writes and
//! their rollback behave exactly as upstream's do.

use std::sync::Mutex;

use zapfast::privacy::{PrivacyChoice, PrivacyKind, Snapshot};

/// A privacy category, in the phone's order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PrivacyKindInfo {
    LastSeen,
    Online,
    Profile,
    About,
    GroupAdd,
    ReadReceipts,
    CallAdd,
}

/// One privacy value; not every value is valid for every category.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum PrivacyChoiceInfo {
    Everyone,
    Contacts,
    /// My contacts except a list the phone edits: shown, never offered.
    Except,
    Nobody,
    SameAsLastSeen,
    /// Calls: silence unknown callers.
    Known,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PrivacyValueInfo {
    pub kind: PrivacyKindInfo,
    pub choice: PrivacyChoiceInfo,
}

macro_rules! mirror {
    ($ours:ident, $theirs:ident, $($variant:ident),+) => {
        impl From<$theirs> for $ours {
            fn from(value: $theirs) -> Self {
                match value { $($theirs::$variant => Self::$variant),+ }
            }
        }
        impl From<$ours> for $theirs {
            fn from(value: $ours) -> Self {
                match value { $($ours::$variant => Self::$variant),+ }
            }
        }
    };
}

mirror!(
    PrivacyKindInfo,
    PrivacyKind,
    LastSeen,
    Online,
    Profile,
    About,
    GroupAdd,
    ReadReceipts,
    CallAdd
);
mirror!(
    PrivacyChoiceInfo,
    PrivacyChoice,
    Everyone,
    Contacts,
    Except,
    Nobody,
    SameAsLastSeen,
    Known
);

/// Every category, in the phone's order (upstream's `PrivacyKind::ALL`).
#[uniffi::export]
pub fn privacy_kinds() -> Vec<PrivacyKindInfo> {
    PrivacyKind::ALL.into_iter().map(Into::into).collect()
}

/// The values the phone offers for a category (upstream's `choices`).
#[uniffi::export]
pub fn privacy_choices(kind: PrivacyKindInfo) -> Vec<PrivacyChoiceInfo> {
    PrivacyKind::from(kind)
        .choices()
        .iter()
        .copied()
        .map(Into::into)
        .collect()
}

/// Upstream's `privacy::Snapshot`: what the phone last reported, with the
/// writes still in flight applied on top.
#[derive(uniffi::Object, Default)]
pub struct PrivacySnapshot {
    inner: Mutex<Snapshot>,
}

#[uniffi::export]
impl PrivacySnapshot {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, kind: PrivacyKindInfo) -> Option<PrivacyChoiceInfo> {
        self.lock().get(kind.into()).map(Into::into)
    }

    pub fn pending(&self, kind: PrivacyKindInfo) -> bool {
        self.lock().pending(kind.into())
    }

    /// Loaded, and the last fetch did not fail.
    pub fn editable(&self) -> bool {
        self.lock().editable()
    }

    pub fn fetch_failed(&self) -> bool {
        self.lock().fetch_failed
    }

    pub fn apply_fetch(&self, values: Vec<PrivacyValueInfo>, failed: bool) {
        let values = values
            .into_iter()
            .map(|value| (value.kind.into(), value.choice.into()))
            .collect();
        self.lock().apply_fetch(values, failed);
    }

    /// Shows `choice` at once; false when nothing should be written.
    pub fn begin_set(&self, kind: PrivacyKindInfo, choice: PrivacyChoiceInfo) -> bool {
        self.lock().begin_set(kind.into(), choice.into())
    }

    /// False for a confirmation nothing waited for.
    pub fn finish_set(&self, kind: PrivacyKindInfo) -> bool {
        self.lock().finish_set(kind.into())
    }

    pub fn fail_set(&self, kind: PrivacyKindInfo) {
        self.lock().fail_set(kind.into());
    }

    /// Forgets everything, as after unlinking.
    pub fn reset(&self) {
        *self.lock() = Snapshot::default();
    }
}

impl PrivacySnapshot {
    fn lock(&self) -> std::sync::MutexGuard<'_, Snapshot> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_write_restores_the_phones_value() {
        let snapshot = PrivacySnapshot::new();
        assert!(!snapshot.editable());
        snapshot.apply_fetch(
            vec![PrivacyValueInfo {
                kind: PrivacyKindInfo::LastSeen,
                choice: PrivacyChoiceInfo::Everyone,
            }],
            false,
        );
        assert!(snapshot.begin_set(PrivacyKindInfo::LastSeen, PrivacyChoiceInfo::Nobody));
        assert!(!snapshot.begin_set(PrivacyKindInfo::LastSeen, PrivacyChoiceInfo::Contacts));
        assert_eq!(
            snapshot.get(PrivacyKindInfo::LastSeen),
            Some(PrivacyChoiceInfo::Nobody)
        );
        snapshot.fail_set(PrivacyKindInfo::LastSeen);
        assert_eq!(
            snapshot.get(PrivacyKindInfo::LastSeen),
            Some(PrivacyChoiceInfo::Everyone)
        );
        assert_eq!(privacy_kinds().len(), 7);
        assert!(!privacy_choices(PrivacyKindInfo::GroupAdd).contains(&PrivacyChoiceInfo::Nobody));
    }
}
