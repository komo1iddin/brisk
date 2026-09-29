use zapfast::backend::LinkStatus;

/// Phone-link state. Pairing payloads are secrets: never log them.
#[derive(Clone, PartialEq, uniffi::Enum)]
pub enum LinkState {
    Starting,
    /// Waiting for a QR scan or for the phone to accept a pairing code.
    Unlinked {
        qr: Option<String>,
        pair_code: Option<String>,
        pairing_phone: Option<String>,
    },
    Connecting,
    Connected,
    /// The connection dropped and reconnects automatically.
    Disconnected {
        reason: String,
    },
    /// The phone unlinked this device.
    LoggedOut,
    Failed {
        message: String,
    },
}

impl From<LinkStatus> for LinkState {
    fn from(status: LinkStatus) -> Self {
        match status {
            LinkStatus::Starting => Self::Starting,
            LinkStatus::Unlinked {
                qr,
                pair_code,
                pairing_phone,
            } => Self::Unlinked {
                qr,
                pair_code,
                pairing_phone,
            },
            LinkStatus::Connecting => Self::Connecting,
            LinkStatus::Connected => Self::Connected,
            LinkStatus::Disconnected { reason } => Self::Disconnected { reason },
            LinkStatus::LoggedOut => Self::LoggedOut,
            LinkStatus::Failed(message) => Self::Failed { message },
        }
    }
}
