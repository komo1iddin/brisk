//! Pure upstream helpers, exported so Swift behaves exactly like upstream
//! instead of keeping its own copy of the rules.

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
