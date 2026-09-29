//! Pure upstream helpers, exported so Swift behaves exactly like upstream
//! instead of keeping its own copy of the rules.

use crate::client::BridgeError;

/// Accent- and case-insensitive key for matching search text.
#[uniffi::export]
pub fn search_key(text: String) -> String {
    zapfast::util::search_key(&text)
}

/// The formatted phone number of a `<digits>@s.whatsapp.net` id.
#[uniffi::export]
pub fn phone_of(id: String) -> Option<String> {
    zapfast::model::phone_of(&id).map(zapfast::util::phone)
}

/// Sample rate of `decode_voice`'s output.
#[uniffi::export]
pub fn voice_sample_rate() -> u32 {
    zapfast::voice::RATE
}

/// Mono samples at `voice_sample_rate()` from a WhatsApp voice message
/// (Opus in OGG, which AVFoundation does not open). Blocking: call it off
/// the main thread.
#[uniffi::export]
pub fn decode_voice(path: String) -> Result<Vec<f32>, BridgeError> {
    let bytes = std::fs::read(&path).map_err(|error| BridgeError::Media {
        message: error.to_string(),
    })?;
    zapfast::voice::decode(&bytes).map_err(|message| BridgeError::Media { message })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_voice_note_upstream_encoded() {
        let rate = voice_sample_rate() as usize;
        let tone: Vec<f32> = (0..rate)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.3)
            .collect();
        let bytes = zapfast::voice::encode(&tone).unwrap();
        let path =
            std::env::temp_dir().join(format!("zapfast-bridge-voice-{}.ogg", std::process::id()));
        std::fs::write(&path, bytes).unwrap();

        let decoded = decode_voice(path.to_string_lossy().into_owned()).unwrap();
        std::fs::remove_file(&path).ok();

        // One second in, one second out, give or take Opus framing.
        assert!(
            (decoded.len() as i64 - rate as i64).abs() < rate as i64 / 10,
            "{}",
            decoded.len()
        );
    }

    #[test]
    fn reports_an_unreadable_file() {
        assert!(matches!(
            decode_voice("/nonexistent/voice.ogg".into()),
            Err(BridgeError::Media { .. })
        ));
    }

    #[test]
    fn formats_phone_ids_like_upstream() {
        assert_eq!(
            phone_of("998901234567@s.whatsapp.net".into()).as_deref(),
            Some("+99 890 123 456 7")
        );
        assert_eq!(phone_of("123@g.us".into()), None);
    }
}
