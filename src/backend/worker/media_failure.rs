//! Why a file could not be fetched, in words that say what to do next.
//!
//! An expired download link makes the worker ask the phone to upload the file
//! again. That can end in four ways that call for different things from the
//! person: the phone has no such file (nothing will help), the phone could not
//! upload it (try again later), the phone did not answer (open WhatsApp on it
//! and try again), or the link to WhatsApp was down. Upstream called all of them
//! "no longer available", which made a phone that was merely asleep look like a
//! file that was gone for good.
//!
//! The texts are matched by the macOS app, which shows its own wording
//! (`DownloadFailure` in ZapFastCore): change one here and change it there.

use whatsapp_rust::{MediaRetryResult, MediaReuploadError};

/// WhatsApp's servers no longer have the file and the phone says it does not
/// either, or the file's link was refused and there was no key to ask with.
pub(super) const MEDIA_GONE: &str = "No longer available on WhatsApp's servers";
/// The phone did not answer the request to upload the file again in time.
pub(super) const PHONE_SILENT: &str =
    "Your phone did not answer. Open WhatsApp on it and try again";
/// The phone answered, but could not upload the file again.
pub(super) const PHONE_REFUSED: &str = "Your phone could not upload it again";
/// The request could not leave: the link to WhatsApp is down.
pub(super) const NOT_CONNECTED: &str = "Not connected to WhatsApp";

/// What to tell the person when asking the phone for a new upload led nowhere.
/// `Ok(Success)` is not a failure and has no text.
pub(super) fn reupload_failure(
    outcome: &Result<MediaRetryResult, MediaReuploadError>,
) -> &'static str {
    match outcome {
        Ok(MediaRetryResult::NotFound) | Ok(MediaRetryResult::Success { .. }) => MEDIA_GONE,
        Ok(MediaRetryResult::GeneralError) | Ok(MediaRetryResult::DecryptionError) => PHONE_REFUSED,
        Err(MediaReuploadError::Timeout) => PHONE_SILENT,
        Err(MediaReuploadError::Client(_)) | Err(MediaReuploadError::NotLoggedIn) => NOT_CONNECTED,
        Err(MediaReuploadError::InvalidRequest(_)) => MEDIA_GONE,
        Err(_) => PHONE_REFUSED,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phone_that_does_not_have_the_file_says_it_is_gone() {
        assert_eq!(
            reupload_failure(&Ok(MediaRetryResult::NotFound)),
            MEDIA_GONE
        );
    }

    #[test]
    fn a_phone_that_tried_and_failed_is_not_a_file_that_is_gone() {
        assert_eq!(
            reupload_failure(&Ok(MediaRetryResult::GeneralError)),
            PHONE_REFUSED
        );
        assert_eq!(
            reupload_failure(&Ok(MediaRetryResult::DecryptionError)),
            PHONE_REFUSED
        );
    }

    #[test]
    fn a_phone_that_stays_silent_is_asked_for_again_not_given_up_on() {
        assert_eq!(
            reupload_failure(&Err(MediaReuploadError::Timeout)),
            PHONE_SILENT
        );
        assert_ne!(PHONE_SILENT, MEDIA_GONE);
    }

    #[test]
    fn a_link_that_was_down_says_so() {
        assert_eq!(
            reupload_failure(&Err(MediaReuploadError::NotLoggedIn)),
            NOT_CONNECTED
        );
    }

    #[test]
    fn a_request_that_does_not_apply_is_gone() {
        assert_eq!(
            reupload_failure(&Err(MediaReuploadError::InvalidRequest("channel".into()))),
            MEDIA_GONE
        );
    }

    /// The macOS app tells these apart by their words.
    #[test]
    fn the_texts_stay_what_the_app_looks_for() {
        assert!(MEDIA_GONE.contains("No longer available"));
        assert!(PHONE_SILENT.contains("did not answer"));
        assert!(PHONE_REFUSED.contains("could not upload it again"));
        assert!(NOT_CONNECTED.contains("Not connected"));
    }
}
