//! Native panes page independently without loading the gap to a search hit.
use super::{Event, WithheldPage, Worker};
use crate::archive::message_window::WindowQuery;
use crate::model::ChatId;

impl Worker {
    pub(super) fn load_message_window(
        &mut self,
        chat: ChatId,
        request: String,
        query: WindowQuery,
    ) {
        if self.withhold(WithheldPage::Window(
            chat.clone(),
            request.clone(),
            query.clone(),
        )) {
            return;
        }
        let (mut messages, has_older, has_newer, error) =
            match self.archive.message_window(&chat, &query) {
                Ok(Some(window)) => (window.messages, window.has_older, window.has_newer, None),
                Ok(None) => (
                    Vec::new(),
                    false,
                    false,
                    Some("This message is not stored on this computer".to_owned()),
                ),
                Err(_) => (
                    Vec::new(),
                    false,
                    false,
                    Some("Could not read the chat archive".to_owned()),
                ),
            };
        for message in &mut messages {
            self.polish(message);
        }
        self.emit(Event::MessageWindow {
            chat,
            request,
            messages,
            has_older,
            has_newer,
            error,
        });
    }
}
