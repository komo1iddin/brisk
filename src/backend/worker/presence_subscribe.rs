//! Asking for a contact's presence (online, last seen) when their chat opens.
//!
//! A chat was marked subscribed before the request went out, and the
//! request fails while the link is still coming up: the chat restored at
//! launch was opened then, so it showed no presence for the whole session,
//! until a relaunch happened to open it after the link was up. A chat opened
//! while the link is down now waits for it instead.

use super::*;

impl Worker {
    /// Subscribes to `chat`'s presence once per session, on a live link.
    pub(super) fn subscribe_presence(&mut self, chat: ChatId) {
        if !matches!(self.status, LinkStatus::Connected) {
            self.presence_waiting.insert(chat);
            return;
        }
        if !self.presence_subscribed.insert(chat.clone()) {
            return;
        }
        let (Some(client), Some(jid)) = (self.client.clone(), Self::jid_of(&chat)) else {
            return;
        };
        tokio::spawn(async move {
            if let Err(error) = client.presence().subscribe(jid).await {
                log::debug!("presence not subscribed: {error}");
            }
        });
    }

    /// The link is up: chats opened while it was down are subscribed now.
    pub(super) fn subscribe_waiting_presence(&mut self) {
        for chat in std::mem::take(&mut self.presence_waiting) {
            self.subscribe_presence(chat);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_chat_opened_before_the_link_is_up_waits_for_it() {
        let (mut worker, _, _, _) = super::super::receipt_tests::worker();
        worker.status = LinkStatus::Connecting;
        worker.subscribe_presence("15550001111@s.whatsapp.net".into());
        assert!(worker.presence_subscribed.is_empty());
        assert!(
            worker
                .presence_waiting
                .contains("15550001111@s.whatsapp.net")
        );

        // Up, with no client in a test: the wait ends and the chat counts
        // as asked, once.
        worker.status = LinkStatus::Connected;
        worker.subscribe_waiting_presence();
        assert!(worker.presence_waiting.is_empty());
        assert!(
            worker
                .presence_subscribed
                .contains("15550001111@s.whatsapp.net")
        );
    }
}
