//! Messages that travel inside another message.
//!
//! WhatsApp sends several kinds of message wrapped in a carrier the receiver
//! may not understand: each picture of an album, a Lottie sticker, and the HD
//! copy of a photo or video sent beside the standard one. A client that does
//! not know the wrapper skips what is inside, which is the point, so reading
//! one means looking past it.
//!
//! The helpers here say what a wrapper holds and what it is for. [`Worker`]
//! uses them to file an album picture as a picture, to give a photo the keys
//! of its HD copy before it is fetched, and to read archived messages again
//! once a wrapper it once skipped is understood.

use super::*;

/// The mimetype of a Lottie sticker's file: a zip holding the animation.
pub(super) const LOTTIE_MIME: &str = "application/was";

/// The message inside a Lottie sticker's wrapper, which carries the sticker.
pub(super) fn lottie_inner(base: &wa::Message) -> Option<&wa::Message> {
    base.lottie_sticker_message
        .as_option()?
        .message
        .as_option()
        .filter(|inner| inner.sticker_message.is_set())
}

/// How a message that travels as the child of another is related to it.
fn association(message: &wa::Message) -> Option<&wa::MessageAssociation> {
    let base = message.get_base_message();
    [base, message]
        .into_iter()
        .filter_map(|outer| outer.message_context_info.as_option())
        .chain(
            base.associated_child_message
                .as_option()
                .and_then(|child| child.message.as_option())
                .and_then(|inner| inner.message_context_info.as_option()),
        )
        .find_map(|context| context.message_association.as_option())
}

fn association_of(message: &wa::Message) -> Option<wa::message_association::AssociationType> {
    association(message)?.association_type
}

/// The picture of an album: WhatsApp wraps each one so that clients which do
/// not know albums skip it, and the wrapper says which album it belongs to.
fn album_inner(base: &wa::Message) -> Option<&wa::Message> {
    use wa::message_association::AssociationType::MEDIA_ALBUM;
    let child = base
        .associated_child_message
        .as_option()?
        .message
        .as_option()?;
    (association_of(base) == Some(MEDIA_ALBUM)).then_some(child)
}

/// The HD copy of a photo or video that is already a message of its own,
/// sent beside it so a client can fetch the better one. The standard copy
/// stands for both.
pub(super) fn is_hd_copy(message: &wa::Message) -> bool {
    use wa::message_association::AssociationType::{
        HD_IMAGE_DUAL_UPLOAD, HD_VIDEO_DUAL_UPLOAD, HEVC_VIDEO_DUAL_UPLOAD,
    };
    message.get_base_message().associated_child_message.is_set()
        && matches!(
            association_of(message),
            Some(HD_IMAGE_DUAL_UPLOAD | HD_VIDEO_DUAL_UPLOAD | HEVC_VIDEO_DUAL_UPLOAD)
        )
}

/// [`MessageExt::get_base_message`], and beyond an album's wrapper: the
/// message that says what was sent.
pub(super) fn base_of(message: &wa::Message) -> &wa::Message {
    let base = message.get_base_message();
    album_inner(base).unwrap_or(base)
}

/// A Lottie sticker is a sticker in a wrapper that clients which cannot play
/// it skip, so what is inside classifies as an ordinary sticker. Its file is
/// a `.was` archive whatever its mimetype says, and it always moves.
pub(super) fn as_lottie(content: Option<Content>) -> Option<Content> {
    Some(match content? {
        Content::Sticker { mut media, .. } => {
            if media.mime.is_empty() {
                media.mime = LOTTIE_MIME.to_owned();
            }
            Content::Sticker {
                media,
                animated: true,
            }
        }
        other => other,
    })
}

impl Worker {
    /// Gives a photo that has not been downloaded yet the keys of its HD
    /// copy, which arrives right after it, so the better picture is the one
    /// fetched. A photo already downloaded, or edited since, is left as it is.
    pub(super) fn upgrade_to_hd(&mut self, chat: &str, copy: &wa::Message) {
        use wa::message_association::AssociationType::HD_IMAGE_DUAL_UPLOAD;
        if association_of(copy) != Some(HD_IMAGE_DUAL_UPLOAD) {
            return;
        }
        let Some(hd) = copy
            .get_base_message()
            .associated_child_message
            .as_option()
            .and_then(|child| child.message.as_option())
            .and_then(|inner| inner.image_message.as_option())
        else {
            return;
        };
        let Some(parent) = association(copy)
            .and_then(|association| association.parent_message_key.as_option())
            .and_then(|key| key.id.clone())
        else {
            return;
        };
        let Ok(Some(mut row)) = self.archive.message(chat, &parent) else {
            return;
        };
        if row.edited || row.content.media().is_none_or(|media| media.path.is_some()) {
            return;
        }
        let Ok(Some(raw)) = self.archive.raw(chat, &parent) else {
            return;
        };
        let Ok(original) = wa::Message::decode_from_slice(&raw) else {
            return;
        };
        let mut base = original.into_base_message();
        let Some(picture) = base.image_message.as_option_mut() else {
            return;
        };
        picture.url = hd.url.clone();
        picture.direct_path = hd.direct_path.clone();
        picture.media_key = hd.media_key.clone();
        picture.media_key_timestamp = hd.media_key_timestamp;
        picture.file_sha256 = hd.file_sha256.clone();
        picture.file_enc_sha256 = hd.file_enc_sha256.clone();
        picture.file_length = hd.file_length;
        picture.width = hd.width;
        picture.height = hd.height;
        if hd.mimetype.is_some() {
            picture.mimetype = hd.mimetype.clone();
        }
        let Some(content) = classify(&base) else {
            return;
        };
        row.content = content;
        if self
            .archive
            .insert_message(&row, Some(&base.encode_to_vec()))
            .is_ok()
        {
            self.emit_message(chat, &parent);
        }
    }

    /// Reads again the archived messages that were filed as unsupported
    /// before the wrapper they travelled in was understood: the pictures of
    /// an album, Lottie stickers, and the HD copy of a photo, which is not a
    /// message of its own and goes. The file is fetched like any other.
    ///
    /// Version 1 rewrote only the content, so album pictures it recovered,
    /// and those that came in history read from their wrapper, lacked their
    /// preview, mentions and forwarded mark; version 2 fills those in.
    pub(super) fn backfill_wrapped_messages(&mut self) {
        const KEY: &str = "wrapped_messages";
        const VERSION: &str = "2";
        let done = self.archive.meta(KEY).ok().flatten();
        if done.as_deref() == Some(VERSION) {
            return;
        }
        let rows = if done.is_some() {
            self.archive.rows_with_raw()
        } else {
            self.archive.unsupported_with_raw()
        };
        let rows = match rows {
            Ok(rows) => rows,
            Err(error) => {
                log::warn!("could not read archived messages: {error}");
                return;
            }
        };
        let (mut recovered, mut removed) = (0, 0);
        for (chat, id, raw) in rows {
            let Ok(message) = wa::Message::decode_from_slice(&raw) else {
                continue;
            };
            if is_hd_copy(&message) {
                if self.archive.delete_message(&chat, &id).unwrap_or(false) {
                    removed += 1;
                }
                continue;
            }
            let base = base_of(&message);
            if done.is_some() && album_inner(message.get_base_message()).is_none() {
                continue;
            }
            let Some(mut content) = classify(&message) else {
                continue;
            };
            if matches!(content, Content::Unsupported { .. }) {
                continue;
            }
            let Ok(Some(existing)) = self.archive.message(&chat, &id) else {
                continue;
            };
            if matches!(existing.content, Content::Revoked) {
                continue;
            }
            if existing.edited && !matches!(existing.content, Content::Unsupported { .. }) {
                // An edited caption is newer than the raw protobuf.
                content = existing.content.clone();
            } else {
                content.keep_local_paths(&existing.content);
            }
            let mentions = self.mentions_of(&mentioned_of(base));
            if self
                .archive
                .set_derived(
                    &chat,
                    &id,
                    &content,
                    &mentions,
                    thumbnail_of(base).as_deref(),
                    forwarded_of(base),
                )
                .is_ok()
            {
                recovered += 1;
            }
        }
        let _ = self.archive.set_meta(KEY, VERSION);
        if recovered + removed > 0 {
            log::info!(
                "recovered {recovered} archived wrapped messages, dropped {removed} HD copies"
            );
            self.emit_chats();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lottie_message(sticker: Option<wa::message::StickerMessage>) -> wa::Message {
        wa::Message {
            lottie_sticker_message: whatsapp_rust::prelude::MessageField::some(
                wa::message::FutureProofMessage {
                    message: whatsapp_rust::prelude::MessageField::some(wa::Message {
                        sticker_message: sticker
                            .map(whatsapp_rust::prelude::MessageField::some)
                            .unwrap_or_default(),
                        ..Default::default()
                    }),
                },
            ),
            ..Default::default()
        }
    }

    /// A picture as WhatsApp sends one that belongs to something else: wrapped
    /// as a child of the message it is associated with.
    fn child_of(kind: wa::message_association::AssociationType) -> wa::Message {
        child_to(kind, "")
    }

    /// The same, a child of the message with this id.
    fn child_to(kind: wa::message_association::AssociationType, parent: &str) -> wa::Message {
        let inner = wa::Message {
            image_message: whatsapp_rust::prelude::MessageField::some(wa::message::ImageMessage {
                mimetype: Some("image/jpeg".into()),
                caption: Some("from the album".into()),
                file_length: Some(10),
                jpeg_thumbnail: Some(vec![1, 2, 3]),
                ..Default::default()
            }),
            ..Default::default()
        };
        let mut child = whatsapp_rust::wacore::proto_helpers::wrap_as_album_child(
            inner,
            wa::MessageKey {
                id: Some(parent.to_owned()),
                ..Default::default()
            },
        );
        if let Some(context) = child.message_context_info.as_option_mut()
            && let Some(association) = context.message_association.as_option_mut()
        {
            association.association_type = Some(kind);
        }
        child
    }

    #[test]
    fn the_pictures_of_an_album_are_pictures() {
        use wa::message_association::AssociationType::MEDIA_ALBUM;
        let child = child_of(MEDIA_ALBUM);
        match classify(&child) {
            Some(Content::Image { caption, media }) => {
                assert_eq!(caption.as_deref(), Some("from the album"));
                assert_eq!(media.mime, "image/jpeg");
            }
            other => panic!("unexpected {other:?}"),
        }
        // Its preview is found inside the wrapper too, for the row.
        assert_eq!(thumbnail_of(base_of(&child)), Some(vec![1, 2, 3]));
    }

    #[test]
    fn the_hd_copy_of_a_photo_is_no_message_of_its_own() {
        use wa::message_association::AssociationType::{
            HD_IMAGE_DUAL_UPLOAD, HD_VIDEO_DUAL_UPLOAD, HEVC_VIDEO_DUAL_UPLOAD,
        };
        for kind in [
            HD_IMAGE_DUAL_UPLOAD,
            HD_VIDEO_DUAL_UPLOAD,
            HEVC_VIDEO_DUAL_UPLOAD,
        ] {
            let copy = child_of(kind);
            assert!(is_hd_copy(&copy));
            assert!(classify(&copy).is_none(), "{kind:?} is hidden");
        }
    }

    fn standard_photo() -> wa::Message {
        wa::Message {
            image_message: whatsapp_rust::prelude::MessageField::some(wa::message::ImageMessage {
                mimetype: Some("image/jpeg".into()),
                caption: Some("holiday".into()),
                direct_path: Some("/standard".into()),
                media_key: Some(vec![1; 32]),
                file_length: Some(100),
                width: Some(1600),
                height: Some(1200),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn hd_copy_of(parent: &str) -> wa::Message {
        let mut copy = child_to(
            wa::message_association::AssociationType::HD_IMAGE_DUAL_UPLOAD,
            parent,
        );
        if let Some(child) = copy.associated_child_message.as_option_mut()
            && let Some(inner) = child.message.as_option_mut()
        {
            inner.image_message =
                whatsapp_rust::prelude::MessageField::some(wa::message::ImageMessage {
                    mimetype: Some("image/jpeg".into()),
                    direct_path: Some("/hd".into()),
                    media_key: Some(vec![9; 32]),
                    file_length: Some(900),
                    width: Some(4000),
                    height: Some(3000),
                    ..Default::default()
                });
        }
        copy
    }

    /// Files the standard photo as a message with its raw protobuf, as
    /// receiving it does, and returns the chat.
    fn file_photo(worker: &mut Worker, edited: bool, path: Option<&str>) -> &'static str {
        let chat = "someone@s.whatsapp.net";
        worker.archive.ensure_chat(chat, "Someone").unwrap();
        let photo = standard_photo();
        let mut content = classify(&photo).unwrap();
        if let Content::Image { media, .. } = &mut content {
            media.path = path.map(PathBuf::from);
        }
        let row = Message {
            id: "photo".into(),
            chat: chat.into(),
            sender: chat.into(),
            sender_name: None,
            from_me: false,
            timestamp: 100,
            content,
            status: Delivery::Read,
            delivered_at: None,
            read_at: None,
            quoted: None,
            reactions: vec![crate::model::Reaction {
                sender: chat.into(),
                from_me: false,
                emoji: "x".into(),
            }],
            edited,
            mentions: Vec::new(),
            forwarded: false,
            history_order: None,
            thumbnail: None,
        };
        worker
            .archive
            .insert_message(&row, Some(&photo.encode_to_vec()))
            .unwrap();
        chat
    }

    #[test]
    fn a_photo_not_downloaded_yet_is_fetched_in_hd() {
        let (mut worker, _events, _, _) = receipt_tests::worker();
        let chat = file_photo(&mut worker, false, None);

        worker.upgrade_to_hd(chat, &hd_copy_of("photo"));

        let row = worker.archive.message(chat, "photo").unwrap().unwrap();
        match &row.content {
            Content::Image { caption, media } => {
                assert_eq!(caption.as_deref(), Some("holiday"), "the caption stays");
                assert_eq!(
                    (media.size, media.width, media.height),
                    (900, Some(4000), Some(3000))
                );
                assert!(media.path.is_none());
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(row.reactions.len(), 1, "what else the row holds stays");
        let raw = worker.archive.raw(chat, "photo").unwrap().unwrap();
        let stored = wa::Message::decode_from_slice(&raw).unwrap();
        let picture = stored.image_message.as_option().unwrap();
        assert_eq!(picture.direct_path.as_deref(), Some("/hd"));
        assert_eq!(picture.media_key.as_deref(), Some(&[9u8; 32][..]));
        assert_eq!(picture.caption.as_deref(), Some("holiday"));
    }

    #[test]
    fn a_photo_already_downloaded_or_edited_keeps_what_it_has() {
        for (edited, path) in [(false, Some("/cache/photo.jpg")), (true, None)] {
            let (mut worker, _events, _, _) = receipt_tests::worker();
            let chat = file_photo(&mut worker, edited, path);

            worker.upgrade_to_hd(chat, &hd_copy_of("photo"));

            let raw = worker.archive.raw(chat, "photo").unwrap().unwrap();
            let stored = wa::Message::decode_from_slice(&raw).unwrap();
            let picture = stored.image_message.as_option().unwrap();
            assert_eq!(picture.direct_path.as_deref(), Some("/standard"));
        }
    }

    #[test]
    fn a_photo_from_history_takes_its_hd_copy_from_the_same_chunk() {
        use receipt_tests::{PEER, file_history_entries, history_entry};
        let (mut worker, _events, _, _) = receipt_tests::worker();
        let chunk = || {
            vec![
                history_entry(
                    PEER,
                    "photo",
                    false,
                    None,
                    standard_photo(),
                    Vec::new(),
                    None,
                ),
                history_entry(
                    PEER,
                    "photo-hd",
                    false,
                    None,
                    hd_copy_of("photo"),
                    Vec::new(),
                    None,
                ),
            ]
        };
        // The second time is a replay, which files the standard photo again.
        for _ in 0..2 {
            file_history_entries(&mut worker, chunk());
            let raw = worker.archive.raw(PEER, "photo").unwrap().unwrap();
            let stored = wa::Message::decode_from_slice(&raw).unwrap();
            let picture = stored.image_message.as_option().unwrap();
            assert_eq!(picture.direct_path.as_deref(), Some("/hd"));
            assert!(worker.archive.message(PEER, "photo-hd").unwrap().is_none());
        }
    }

    #[test]
    fn an_hd_copy_of_nothing_we_have_changes_nothing() {
        let (mut worker, _events, _, _) = receipt_tests::worker();
        let chat = file_photo(&mut worker, false, None);
        worker.upgrade_to_hd(chat, &hd_copy_of("elsewhere"));
        worker.upgrade_to_hd(chat, &hd_copy_of(""));
        // An album's picture is not an HD copy, whatever it is a child of.
        worker.upgrade_to_hd(
            chat,
            &child_to(
                wa::message_association::AssociationType::MEDIA_ALBUM,
                "photo",
            ),
        );
        let raw = worker.archive.raw(chat, "photo").unwrap().unwrap();
        let stored = wa::Message::decode_from_slice(&raw).unwrap();
        assert_eq!(
            stored
                .image_message
                .as_option()
                .unwrap()
                .direct_path
                .as_deref(),
            Some("/standard")
        );
    }

    #[test]
    fn an_album_picture_from_history_keeps_its_preview() {
        use wa::message_association::AssociationType::MEDIA_ALBUM;
        let parsed = parse_conversation(wa::Conversation {
            id: super::receipt_tests::PEER.into(),
            messages: vec![super::receipt_tests::history_entry(
                super::receipt_tests::PEER,
                "album-photo",
                false,
                None,
                child_of(MEDIA_ALBUM),
                Vec::new(),
                None,
            )],
            ..Default::default()
        });
        let message = &parsed.messages[0];
        assert_eq!(message.thumbnail.as_deref(), Some(&[1, 2, 3][..]));
    }

    #[test]
    fn an_album_picture_is_forwarded_alone() {
        use wa::message_association::AssociationType::MEDIA_ALBUM;
        let (forward, _) = outgoing_forward(&child_of(MEDIA_ALBUM), None);
        assert!(forward.associated_child_message.is_unset());
        assert!(forward.message_context_info.is_unset());
        let picture = forward
            .image_message
            .as_option()
            .expect("the picture itself");
        assert_eq!(picture.caption.as_deref(), Some("from the album"));
        assert_eq!(
            picture
                .context_info
                .as_option()
                .and_then(|c| c.is_forwarded),
            Some(true)
        );
    }

    #[test]
    fn a_child_of_another_kind_is_still_shown_as_unsupported() {
        use wa::message_association::AssociationType::{MEDIA_ALBUM, STATUS_POLL};
        let other = child_of(STATUS_POLL);
        assert!(!is_hd_copy(&other));
        assert!(matches!(
            classify(&other),
            Some(Content::Unsupported { .. })
        ));
        // And an ordinary picture is neither wrapped nor hidden.
        let plain = wa::Message {
            image_message: whatsapp_rust::prelude::MessageField::some(Default::default()),
            ..Default::default()
        };
        assert!(!is_hd_copy(&plain));
        assert!(album_inner(&plain).is_none());
        assert!(album_inner(&child_of(MEDIA_ALBUM)).is_some());
    }

    #[test]
    fn a_lottie_sticker_is_a_sticker_that_moves() {
        let message = lottie_message(Some(wa::message::StickerMessage {
            mimetype: Some("application/was".into()),
            file_length: Some(2048),
            is_lottie: Some(true),
            ..Default::default()
        }));
        match classify(&message) {
            Some(Content::Sticker { media, animated }) => {
                assert!(animated, "Lottie stickers move");
                assert_eq!(media.mime, "application/was");
                assert_eq!(media.size, 2048);
            }
            other => panic!("unexpected {other:?}"),
        }
        // Without a mimetype the file is still known for what it is.
        let bare = lottie_message(Some(wa::message::StickerMessage::default()));
        match classify(&bare) {
            Some(Content::Sticker { media, .. }) => assert_eq!(media.mime, LOTTIE_MIME),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn a_lottie_wrapper_without_a_sticker_stays_unsupported() {
        assert!(lottie_inner(&lottie_message(None)).is_none());
        match classify(&lottie_message(None)) {
            Some(Content::Unsupported { what }) => assert_eq!(what, "animated sticker"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn album_pictures_recovered_before_get_their_preview_and_keep_their_file() {
        use wa::message_association::AssociationType::MEDIA_ALBUM;
        let (mut worker, _events, _, _) = receipt_tests::worker();
        let chat = "someone@s.whatsapp.net";
        worker.archive.ensure_chat(chat, "Someone").unwrap();
        let album = child_of(MEDIA_ALBUM);
        let mut content = classify(&album).unwrap();
        if let Some(media) = content.media_mut() {
            media.path = Some("/files/album.jpg".into());
        }
        // As version 1 left it: the picture, without its preview.
        let filed = Message {
            id: "album".into(),
            chat: chat.into(),
            sender: chat.into(),
            sender_name: None,
            from_me: false,
            timestamp: 100,
            content,
            status: Delivery::Read,
            delivered_at: None,
            read_at: None,
            quoted: None,
            reactions: Vec::new(),
            edited: false,
            mentions: Vec::new(),
            forwarded: false,
            history_order: None,
            thumbnail: None,
        };
        worker
            .archive
            .insert_message(&filed, Some(&album.encode_to_vec()))
            .unwrap();
        worker.archive.set_meta("wrapped_messages", "1").unwrap();

        worker.backfill_wrapped_messages();

        let stored = worker.archive.message(chat, "album").unwrap().unwrap();
        assert_eq!(stored.thumbnail.as_deref(), Some(&[1, 2, 3][..]));
        assert_eq!(
            stored
                .content
                .media()
                .and_then(|media| media.path.as_deref()),
            Some(std::path::Path::new("/files/album.jpg"))
        );
        assert_eq!(
            worker.archive.meta("wrapped_messages").unwrap().as_deref(),
            Some("2")
        );
    }

    #[test]
    fn wrapped_messages_filed_as_unsupported_are_recovered_once() {
        use wa::message_association::AssociationType::{HD_IMAGE_DUAL_UPLOAD, MEDIA_ALBUM};
        let (mut worker, _events, _, _) = receipt_tests::worker();
        let chat = "someone@s.whatsapp.net";
        worker.archive.ensure_chat(chat, "Someone").unwrap();
        let file = |id: &str, what: &str, at: i64, message: &wa::Message| {
            let filed = Message {
                id: id.into(),
                chat: chat.into(),
                sender: chat.into(),
                sender_name: None,
                from_me: false,
                timestamp: at,
                content: Content::Unsupported { what: what.into() },
                status: Delivery::Read,
                delivered_at: None,
                read_at: None,
                quoted: None,
                reactions: Vec::new(),
                edited: false,
                mentions: Vec::new(),
                forwarded: false,
                history_order: None,
                thumbnail: None,
            };
            worker
                .archive
                .insert_message(&filed, Some(&message.encode_to_vec()))
                .unwrap();
        };
        let lottie = lottie_message(Some(wa::message::StickerMessage {
            mimetype: Some("application/was".into()),
            ..Default::default()
        }));
        file("lottie", "animated sticker", 100, &lottie);
        file("album", "message", 200, &child_of(MEDIA_ALBUM));
        file("hd", "message", 300, &child_of(HD_IMAGE_DUAL_UPLOAD));
        // Something nobody understands stays as it was.
        let unknown = wa::Message {
            lottie_sticker_message: whatsapp_rust::prelude::MessageField::some(Default::default()),
            ..Default::default()
        };
        file("unknown", "message", 400, &unknown);

        worker.backfill_wrapped_messages();

        let stored = |id: &str| worker.archive.message(chat, id).unwrap();
        assert!(matches!(
            stored("lottie").unwrap().content,
            Content::Sticker { animated: true, .. }
        ));
        assert!(matches!(
            stored("album").unwrap().content,
            Content::Image { .. }
        ));
        assert!(stored("hd").is_none(), "the HD copy is gone");
        assert!(matches!(
            stored("unknown").unwrap().content,
            Content::Unsupported { .. }
        ));
        assert_eq!(
            stored("album").unwrap().thumbnail.as_deref(),
            Some(&[1, 2, 3][..]),
            "with the preview it travelled with"
        );
        assert_eq!(
            worker.archive.meta("wrapped_messages").unwrap().as_deref(),
            Some("2")
        );
    }
}
