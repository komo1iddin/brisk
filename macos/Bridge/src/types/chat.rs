use zapfast::model::{self, Chat, LastMessage};
use zapfast::settings::NotificationSound;

/// The sound a notification makes (upstream's `NotificationSound`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum NotificationSoundInfo {
    /// Pidgin's message sound, upstream's default for new messages.
    Receive,
    /// Pidgin's alert sound, the default for mentions and replies to us.
    Alert,
    /// What the system plays for notifications.
    System,
    None,
    /// An audio file.
    Custom {
        path: String,
    },
}

impl From<NotificationSound> for NotificationSoundInfo {
    fn from(sound: NotificationSound) -> Self {
        match sound {
            NotificationSound::Receive => Self::Receive,
            NotificationSound::Alert => Self::Alert,
            NotificationSound::System => Self::System,
            NotificationSound::None => Self::None,
            NotificationSound::Custom(path) => Self::Custom {
                path: super::path_string(path),
            },
        }
    }
}

impl From<NotificationSoundInfo> for NotificationSound {
    fn from(sound: NotificationSoundInfo) -> Self {
        match sound {
            NotificationSoundInfo::Receive => Self::Receive,
            NotificationSoundInfo::Alert => Self::Alert,
            NotificationSoundInfo::System => Self::System,
            NotificationSoundInfo::None => Self::None,
            NotificationSoundInfo::Custom { path } => Self::Custom(path.into()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChatKind {
    Direct,
    Group,
    /// Read-only newsletter or broadcast list.
    Broadcast,
}

impl From<model::ChatKind> for ChatKind {
    fn from(kind: model::ChatKind) -> Self {
        match kind {
            model::ChatKind::Direct => Self::Direct,
            model::ChatKind::Group => Self::Group,
            model::ChatKind::Broadcast => Self::Broadcast,
        }
    }
}

/// Outgoing-message delivery state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DeliveryState {
    /// Incoming message, no receipts of ours.
    None,
    Pending,
    Sent,
    Delivered,
    Read,
    Played,
    Failed,
}

impl From<model::Delivery> for DeliveryState {
    fn from(delivery: model::Delivery) -> Self {
        match delivery {
            model::Delivery::None => Self::None,
            model::Delivery::Pending => Self::Pending,
            model::Delivery::Sent => Self::Sent,
            model::Delivery::Delivered => Self::Delivered,
            model::Delivery::Read => Self::Read,
            model::Delivery::Played => Self::Played,
            model::Delivery::Failed => Self::Failed,
        }
    }
}

/// The latest message as the chat list shows it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatPreview {
    pub from_me: bool,
    pub sender: String,
    /// Group sender's name.
    pub sender_name: Option<String>,
    /// One line.
    pub summary: String,
    /// Every line, for a tooltip.
    pub full: String,
    pub status: DeliveryState,
}

impl From<LastMessage> for ChatPreview {
    fn from(last: LastMessage) -> Self {
        let LastMessage {
            from_me,
            sender,
            sender_name,
            summary,
            full,
            status,
        } = last;
        Self {
            from_me,
            sender,
            sender_name,
            summary,
            full,
            status: status.into(),
        }
    }
}

/// One chat as the chat list and conversation header need it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatSummary {
    pub id: String,
    /// Best known address-book, push, or phone-number name.
    pub name: String,
    pub group_subject_known: bool,
    pub kind: ChatKind,
    /// Latest-message Unix seconds, for ordering.
    pub last_activity: i64,
    pub unread: u32,
    /// Marked unread without a count.
    pub marked_unread: bool,
    pub archived: bool,
    pub pinned: bool,
    /// Pin time in Unix milliseconds, zero when unknown.
    pub pinned_at: i64,
    /// Mute end in Unix seconds; `Some(0)` means indefinitely.
    pub muted_until: Option<i64>,
    pub last: Option<ChatPreview>,
    pub favorite: bool,
    pub favorite_position: u32,
    /// Canonical member ids, empty until loaded.
    pub participants: Vec<String>,
    /// Announcement group where we cannot post.
    pub read_only: bool,
    pub left: bool,
    /// Only admins may edit name and photo; `None` until known.
    pub info_locked: Option<bool>,
    pub admin: bool,
    /// Hidden behind WhatsApp chat lock.
    pub locked: bool,
    /// Disappearing-message duration in seconds.
    pub ephemeral_expiration: Option<u32>,
    /// Local label ids.
    pub labels: Vec<String>,
    /// Whether the chat has its own notification sound.
    pub has_custom_sound: bool,
    /// A followed channel (newsletter).
    pub is_channel: bool,
    /// Counted unread, or marked unread.
    pub looks_unread: bool,
    /// Formatted phone number for a direct chat.
    pub phone: Option<String>,
    /// The chat's own notification sound; `None` follows Settings.
    #[uniffi(default = None)]
    pub notification_sound: Option<NotificationSoundInfo>,
}

impl From<Chat> for ChatSummary {
    fn from(chat: Chat) -> Self {
        let is_channel = chat.is_channel();
        let looks_unread = chat.looks_unread();
        let phone = chat.phone().map(zapfast::util::phone);
        let Chat {
            id,
            name,
            group_subject_known,
            kind,
            last_activity,
            unread,
            marked_unread,
            archived,
            pinned,
            pinned_at,
            muted_until,
            last,
            favorite,
            favorite_position,
            participants,
            read_only,
            left,
            info_locked,
            admin,
            locked,
            ephemeral_expiration,
            labels,
            notification_sound,
        } = chat;
        Self {
            id,
            name,
            group_subject_known,
            kind: kind.into(),
            last_activity,
            unread,
            marked_unread,
            archived,
            pinned,
            pinned_at,
            muted_until,
            last: last.map(Into::into),
            favorite,
            favorite_position,
            participants,
            read_only,
            left,
            info_locked,
            admin,
            locked,
            ephemeral_expiration,
            labels,
            has_custom_sound: notification_sound.is_some(),
            notification_sound: notification_sound.map(Into::into),
            is_channel,
            looks_unread,
            phone,
        }
    }
}

/// A label, kept on this computer only.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LabelInfo {
    pub id: String,
    pub name: String,
    /// `#rrggbb`, lower case.
    pub color_hex: String,
    pub created_at: i64,
}

impl From<zapfast::model::Label> for LabelInfo {
    fn from(label: zapfast::model::Label) -> Self {
        let zapfast::model::Label {
            id,
            name,
            color_hex,
            created_at,
        } = label;
        Self {
            id,
            name,
            color_hex,
            created_at,
        }
    }
}
