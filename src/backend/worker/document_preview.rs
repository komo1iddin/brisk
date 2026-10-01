//! A document's page preview. WhatsApp sends documents with a tiny inline
//! preview or none, and keeps a sharper one on its media servers
//! (`thumbnail_direct_path`), encrypted with the document's own media key
//! under the document-thumbnail key derivation. whatsapp-rust has no media
//! type for it, so the encrypted bytes are fetched through the client as
//! plain bytes checked against their hash, and decrypted here with
//! whatsapp-rust's primitives.

use super::*;
use whatsapp_rust::wacore::crypto::hkdf_sha256_into;
use whatsapp_rust::wacore::libsignal::crypto::{
    aes_256_cbc_decrypt_in_place, hmac_sha256_two_part,
};

/// The derivation WhatsApp uses for document thumbnails. The others are
/// tried after it, in case a sender's client derived the keys as for the
/// document or an image; the MAC tells which one was used.
const APP_INFOS: [&[u8]; 3] = [
    b"WhatsApp Document Thumbnail Keys",
    b"WhatsApp Document Keys",
    b"WhatsApp Image Keys",
];

/// Trailing HMAC bytes on every encrypted media payload.
const MAC_SIZE: usize = 10;

/// A stored preview at least this large is already the sharp one.
pub(super) const SHARP_PREVIEW_BYTES: usize = 10_000;

/// How long a preview may take to arrive.
pub(super) const PREVIEW_TIMEOUT: Duration = Duration::from_secs(30);

pub(super) struct DocumentPreview {
    direct_path: String,
    media_key: Vec<u8>,
    enc_sha256: Vec<u8>,
    sha256: Option<Vec<u8>>,
}

impl DocumentPreview {
    /// The preview's references, when the message is a document that has one.
    pub(super) fn of(message: &wa::Message) -> Option<Self> {
        let document = message.document_message.as_option()?;
        let present = |bytes: &Option<Vec<u8>>| bytes.clone().filter(|bytes| !bytes.is_empty());
        Some(Self {
            direct_path: document
                .thumbnail_direct_path
                .clone()
                .filter(|path| !path.is_empty())?,
            media_key: present(&document.media_key)?,
            enc_sha256: present(&document.thumbnail_enc_sha256)?,
            sha256: present(&document.thumbnail_sha256),
        })
    }

    /// Authenticates and decrypts the downloaded payload: the JPEG.
    pub(super) fn decrypt(&self, payload: Vec<u8>) -> Result<Vec<u8>, String> {
        if payload.len() <= MAC_SIZE {
            return Err("The preview is empty".to_owned());
        }
        let split = payload.len() - MAC_SIZE;
        for info in APP_INFOS {
            let keys = MediaKeys::expand(&self.media_key, info)?;
            let mac = hmac_sha256_two_part(&keys.mac, &keys.iv, &payload[..split]);
            if mac[..MAC_SIZE] != payload[split..] {
                continue;
            }
            let mut plain = payload[..split].to_vec();
            aes_256_cbc_decrypt_in_place(&mut plain, &keys.cipher, &keys.iv)
                .map_err(|_| "The preview could not be decrypted".to_owned())?;
            if let Some(expected) = &self.sha256
                && <sha2::Sha256 as sha2::Digest>::digest(&plain).as_slice() != expected.as_slice()
            {
                return Err("The preview does not match its hash".to_owned());
            }
            return Ok(plain);
        }
        Err("The preview failed its integrity check".to_owned())
    }
}

/// Fetched without the client's decryption: the bytes are checked against
/// the encrypted hash, which is also the URL token encrypted media uses.
impl Downloadable for DocumentPreview {
    fn direct_path(&self) -> Option<&str> {
        Some(&self.direct_path)
    }

    fn media_key(&self) -> Option<&[u8]> {
        None
    }

    fn file_enc_sha256(&self) -> Option<&[u8]> {
        None
    }

    fn file_sha256(&self) -> Option<&[u8]> {
        Some(&self.enc_sha256)
    }

    fn file_length(&self) -> Option<u64> {
        None
    }

    fn app_info(&self) -> MediaType {
        MediaType::Document
    }
}

/// The IV, cipher key and MAC key a media key expands to under an info.
struct MediaKeys {
    iv: [u8; 16],
    cipher: [u8; 32],
    mac: [u8; 32],
}

impl MediaKeys {
    fn expand(media_key: &[u8], info: &[u8]) -> Result<Self, String> {
        let mut expanded = [0u8; 112];
        hkdf_sha256_into(media_key, None, info, &mut expanded)
            .map_err(|_| "The preview's keys could not be derived".to_owned())?;
        let mut keys = Self {
            iv: [0; 16],
            cipher: [0; 32],
            mac: [0; 32],
        };
        keys.iv.copy_from_slice(&expanded[..16]);
        keys.cipher.copy_from_slice(&expanded[16..48]);
        keys.mac.copy_from_slice(&expanded[48..80]);
        Ok(keys)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use whatsapp_rust::wacore::libsignal::crypto::aes_256_cbc_encrypt_into;

    fn encrypted(media_key: &[u8], info: &[u8], plain: &[u8]) -> Vec<u8> {
        let keys = MediaKeys::expand(media_key, info).expect("keys");
        let mut payload = Vec::new();
        aes_256_cbc_encrypt_into(plain, &keys.cipher, &keys.iv, &mut payload).expect("encrypt");
        let mac = hmac_sha256_two_part(&keys.mac, &keys.iv, &payload);
        payload.extend_from_slice(&mac[..MAC_SIZE]);
        payload
    }

    fn preview(media_key: &[u8], plain: &[u8]) -> DocumentPreview {
        DocumentPreview {
            direct_path: "/v/t62.36145-24/preview".to_owned(),
            media_key: media_key.to_vec(),
            enc_sha256: vec![1],
            sha256: Some(<sha2::Sha256 as sha2::Digest>::digest(plain).to_vec()),
        }
    }

    #[test]
    fn a_preview_decrypts_under_the_document_thumbnail_keys() {
        let key = [7u8; 32];
        let jpeg = b"\xff\xd8\xff\xe0 a page".to_vec();
        let payload = encrypted(&key, APP_INFOS[0], &jpeg);
        assert_eq!(preview(&key, &jpeg).decrypt(payload), Ok(jpeg));
    }

    #[test]
    fn a_preview_derived_as_the_document_still_decrypts() {
        let key = [9u8; 32];
        let jpeg = b"\xff\xd8\xff\xe0 another page".to_vec();
        let payload = encrypted(&key, b"WhatsApp Document Keys", &jpeg);
        assert_eq!(preview(&key, &jpeg).decrypt(payload), Ok(jpeg));
    }

    #[test]
    fn a_tampered_or_mismatched_preview_is_refused() {
        let key = [7u8; 32];
        let jpeg = b"\xff\xd8\xff\xe0 a page".to_vec();
        let mut payload = encrypted(&key, APP_INFOS[0], &jpeg);
        payload[0] ^= 1;
        assert!(preview(&key, &jpeg).decrypt(payload).is_err());
        let other = encrypted(&key, APP_INFOS[0], b"something else");
        assert!(preview(&key, &jpeg).decrypt(other).is_err());
        assert!(preview(&key, &jpeg).decrypt(vec![0; 4]).is_err());
    }

    #[test]
    fn only_a_document_with_a_stored_preview_has_one() {
        let document = |path: Option<&str>| wa::Message {
            document_message: MessageField::some(wa::message::DocumentMessage {
                thumbnail_direct_path: path.map(str::to_owned),
                media_key: Some(vec![1; 32]),
                thumbnail_enc_sha256: Some(vec![2; 32]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(DocumentPreview::of(&document(Some("/v/preview"))).is_some());
        assert!(DocumentPreview::of(&document(None)).is_none());
        assert!(DocumentPreview::of(&document(Some(""))).is_none());
        assert!(DocumentPreview::of(&wa::Message::default()).is_none());
    }
}
