//! How to name a chat when asking the phone about it.
//!
//! The archive files a direct chat under its phone number once the privacy id
//! (`@lid`) behind it is known, so the chat list stays one list. The phone
//! does not: WhatsApp has moved direct chats to privacy ids, and a request that
//! names such a chat by phone number is ignored, with no answer at all. The
//! request for older messages and the request to upload a file again are both
//! answered only when they name the chat the way the phone does, which for a
//! direct chat with a known privacy id is that id. Groups have one name.

use super::*;

impl Worker {
    /// The address to ask the phone about `chat` by.
    pub(super) fn phone_jid(&self, chat: &str) -> Option<Jid> {
        phone_address(chat, |jid| self.alt_jid(jid))
    }
}

/// `chat` as the phone names it: its privacy id when it is a direct chat
/// `other_name` knows one for, otherwise its own id.
fn phone_address(chat: &str, other_name: impl Fn(&Jid) -> Option<Jid>) -> Option<Jid> {
    let jid: Jid = chat.parse().ok()?;
    if jid.is_pn()
        && let Some(lid) = other_name(&jid)
        && lid.is_lid()
    {
        return Some(lid);
    }
    Some(jid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known(jid: &Jid) -> Option<Jid> {
        (jid.user_base() == "15550003333")
            .then(|| "987654321012345@lid".parse().ok())
            .flatten()
    }

    #[test]
    fn a_direct_chat_with_a_known_privacy_id_is_asked_about_by_that_id() {
        let jid = phone_address("15550003333@s.whatsapp.net", known).expect("address");
        assert_eq!(jid.to_string(), "987654321012345@lid");
    }

    #[test]
    fn a_direct_chat_without_one_keeps_its_phone_number() {
        let jid = phone_address("15550004444@s.whatsapp.net", known).expect("address");
        assert_eq!(jid.to_string(), "15550004444@s.whatsapp.net");
    }

    #[test]
    fn a_group_keeps_its_own_id() {
        let jid = phone_address("120363000000000000@g.us", |_| {
            panic!("a group has no other name")
        })
        .expect("address");
        assert_eq!(jid.to_string(), "120363000000000000@g.us");
    }

    #[test]
    fn a_chat_already_named_by_a_privacy_id_stays_so() {
        let jid = phone_address("987654321012345@lid", |_| panic!("already a privacy id"))
            .expect("address");
        assert_eq!(jid.to_string(), "987654321012345@lid");
    }

    #[test]
    fn something_that_is_no_address_is_none() {
        assert!(phone_address("not an address", known).is_none());
    }
}
