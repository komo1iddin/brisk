use zapfast::model::{MessageReceipts, Recipient};

use super::count;

/// One recipient's receipts for one of our group messages.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RecipientInfo {
    pub id: String,
    /// Named in the audience saved when the message was sent.
    pub expected: bool,
    pub delivered_at: Option<i64>,
    pub read_at: Option<i64>,
    pub played_at: Option<i64>,
}

impl From<&Recipient> for RecipientInfo {
    fn from(recipient: &Recipient) -> Self {
        let Recipient {
            id,
            expected,
            delivered_at,
            read_at,
            played_at,
        } = recipient.clone();
        Self {
            id,
            expected,
            delivered_at,
            read_at,
            played_at,
        }
    }
}

/// "Message info" for one of our group messages, sorted into upstream's
/// sections (`MessageReceipts::played`, `read`, `delivered`, `remaining`)
/// so Swift does not keep its own copy of the rules.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MessageReceiptsInfo {
    pub chat: String,
    pub message: String,
    /// Any receipt at all was recorded.
    pub recorded: bool,
    /// The audience was saved, so members without a receipt are waiting.
    pub audience_known: bool,
    /// Newest first in each section.
    pub played: Vec<RecipientInfo>,
    pub read: Vec<RecipientInfo>,
    pub delivered: Vec<RecipientInfo>,
    /// Audience members with no receipt yet.
    pub remaining: u32,
}

impl From<MessageReceipts> for MessageReceiptsInfo {
    fn from(receipts: MessageReceipts) -> Self {
        let list = |rows: Vec<&Recipient>| rows.into_iter().map(Into::into).collect();
        let played = list(receipts.played());
        let read = list(receipts.read());
        let delivered = list(receipts.delivered());
        let remaining = count(receipts.remaining());
        let audience_known = receipts.audience_known();
        let MessageReceipts {
            chat,
            message,
            recipients,
        } = receipts;
        Self {
            chat,
            message,
            recorded: !recipients.is_empty(),
            audience_known,
            played,
            read,
            delivered,
            remaining,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn recipient(id: &str, delivered: Option<i64>, read: Option<i64>) -> Recipient {
        Recipient {
            id: id.into(),
            expected: true,
            delivered_at: delivered,
            read_at: read,
            played_at: None,
        }
    }

    #[test]
    fn sorts_recipients_into_upstreams_sections() {
        let info = MessageReceiptsInfo::from(MessageReceipts {
            chat: "g@g.us".into(),
            message: "m".into(),
            recipients: vec![
                recipient("a", Some(1), Some(5)),
                recipient("b", Some(2), Some(9)),
                recipient("c", Some(3), None),
                recipient("d", None, None),
            ],
        });
        let ids = |rows: &[RecipientInfo]| rows.iter().map(|r| r.id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(&info.read), ["b", "a"]);
        assert_eq!(ids(&info.delivered), ["c"]);
        assert!(info.played.is_empty());
        assert_eq!(info.remaining, 1);
        assert!(info.recorded && info.audience_known);
    }
}
