//! Shared contact cards (vCard), read as upstream's contact bubble reads
//! them. Upstream keeps these rules private to `src/ui/conversation.rs`
//! (`vcard_tel_preference`, `vcard_tel_account`, `shared_contact_details`),
//! so they are repeated here verbatim, with their tests, until they are
//! public upstream.

fn vcard_tel_preference(property: &str) -> Option<u8> {
    let mut best = None;
    for parameter in property.split(';').skip(1) {
        let (name, value) = parameter.split_once('=').unwrap_or(("TYPE", parameter));
        let value = value.trim_matches('"');
        let rank = if name.eq_ignore_ascii_case("PREF") {
            value
                .parse::<u8>()
                .ok()
                .filter(|rank| (1..=100).contains(rank))
        } else if name.eq_ignore_ascii_case("TYPE")
            && value
                .split(',')
                .any(|value| value.eq_ignore_ascii_case("PREF"))
        {
            Some(1)
        } else {
            None
        };
        if let Some(rank) = rank {
            best = Some(best.map_or(rank, |current: u8| current.min(rank)));
        }
    }
    best
}

/// The first card of a shared contact, as the bubble uses it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SharedContact {
    pub name: String,
    /// The telephone number as the card writes it.
    pub number: String,
    /// The WhatsApp account behind the number, in digits: the `waid`
    /// parameter WhatsApp adds, or a number written in international form.
    /// A local number without a country code cannot name one.
    pub account: Option<String>,
}

fn vcard_tel_account(property: &str, value: &str) -> Option<String> {
    let digits = |text: &str| {
        text.chars()
            .filter(char::is_ascii_digit)
            .collect::<String>()
    };
    let waid = property.split(';').skip(1).find_map(|parameter| {
        let (name, value) = parameter.split_once('=')?;
        name.eq_ignore_ascii_case("WAID")
            .then(|| digits(value.trim_matches('"')))
    });
    waid.or_else(|| value.trim().starts_with('+').then(|| digits(value)))
        .filter(|account| account.len() >= 7)
}

fn shared_contact_details(vcard: &str, fallback_name: &str) -> Option<SharedContact> {
    let mut name = None;
    let mut first_phone = None;
    let mut preferred_phone: Option<(u8, (String, Option<String>))> = None;
    let mut first_card: Vec<String> = Vec::new();
    for line in vcard.lines() {
        let line = line.trim_end_matches('\r');
        if line.starts_with([' ', '\t']) {
            if let Some(previous) = first_card.last_mut() {
                previous.push_str(line.trim_start());
            }
            continue;
        }
        if line.eq_ignore_ascii_case("END:VCARD") && !first_card.is_empty() {
            break;
        }
        if line.eq_ignore_ascii_case("BEGIN:VCARD") {
            if first_card.is_empty() {
                first_card.push(line.to_owned());
            }
            continue;
        }
        if !first_card.is_empty() {
            first_card.push(line.to_owned());
        }
    }
    if first_card.is_empty() {
        first_card.extend(vcard.lines().map(str::to_owned));
    }
    for line in first_card {
        let Some((property, value)) = line.split_once(':') else {
            continue;
        };
        let raw_name = property.split(';').next().unwrap_or(property);
        let property_name = raw_name.rsplit('.').next().unwrap_or(raw_name);
        if property_name.eq_ignore_ascii_case("FN") {
            name = Some(value.trim().to_owned());
        } else if property_name.eq_ignore_ascii_case("TEL") {
            let number = value.trim().to_owned();
            if number.chars().filter(char::is_ascii_digit).count() < 7 {
                continue;
            }
            let phone = (number, vcard_tel_account(property, value));
            if let Some(rank) = vcard_tel_preference(property) {
                let replace = preferred_phone
                    .as_ref()
                    .is_none_or(|(best_rank, _)| rank < *best_rank);
                if replace {
                    preferred_phone = Some((rank, phone));
                }
            } else if first_phone.is_none() {
                first_phone = Some(phone);
            }
        }
    }
    let (number, account) = preferred_phone.map(|(_, phone)| phone).or(first_phone)?;
    let name = name
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| fallback_name.to_owned());
    Some(SharedContact {
        name,
        number,
        account,
    })
}

/// The first card's name, preferred number, and the WhatsApp account
/// behind it, or `None` when the card has no usable number.
#[uniffi::export]
pub fn shared_contact(vcard: String, fallback_name: String) -> Option<SharedContact> {
    shared_contact_details(&vcard, &fallback_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contact(name: &str, number: &str, account: Option<&str>) -> Option<SharedContact> {
        Some(SharedContact {
            name: name.to_owned(),
            number: number.to_owned(),
            account: account.map(str::to_owned),
        })
    }

    #[test]
    fn shared_contact_accepts_case_insensitive_vcard_property_names() {
        assert_eq!(
            shared_contact_details(
                "BEGIN:VCARD\nversion:3.0\nitem1.fn:Case-insensitive name\nitem1.tel;type=cell;waid=1234567:+1 234567\nEND:VCARD",
                "Fallback",
            ),
            contact("Case-insensitive name", "+1 234567", Some("1234567"))
        );
    }

    #[test]
    fn shared_contact_uses_first_valid_telephone_when_multiple_are_present() {
        assert_eq!(
            shared_contact_details(
                "BEGIN:VCARD\nFN:Two numbers\nTEL;TYPE=HOME:+1111111\nTEL;TYPE=CELL:+2222222\nEND:VCARD",
                "Fallback",
            ),
            contact("Two numbers", "+1111111", Some("1111111"))
        );
    }

    #[test]
    fn shared_contact_prefers_lowest_vcard_tel_preference() {
        assert_eq!(
            shared_contact_details(
                "BEGIN:VCARD\nFN:Preferred number\nTEL;TYPE=HOME:+1111111\nitem1.TEL;TYPE=CELL;PREF=2:+2222222\nTEL;TYPE=WORK;PREF=1:+3333333\nEND:VCARD",
                "Fallback",
            ),
            contact("Preferred number", "+3333333", Some("3333333"))
        );
    }

    #[test]
    fn shared_contact_prefers_vcard_name_and_reads_the_account_from_waid() {
        assert_eq!(
            shared_contact_details(
                "BEGIN:VCARD\nVERSION:3.0\nFN:Alice Example\nitem1.TEL;waid=15550101234:+1 (555) 010-1234\nEND:VCARD",
                "Contact from sender",
            ),
            contact("Alice Example", "+1 (555) 010-1234", Some("15550101234"))
        );
    }

    #[test]
    fn a_local_number_names_no_account_and_stays_readable() {
        // Without a country code the digits are not a WhatsApp account.
        assert_eq!(
            shared_contact_details(
                "BEGIN:VCARD\nFN:Local\nTEL;TYPE=CELL:0171 1234567\nEND:VCARD",
                "Fallback",
            ),
            contact("Local", "0171 1234567", None)
        );
    }

    #[test]
    fn shared_contact_without_vcard_name_uses_message_name_and_rejects_missing_phone() {
        assert_eq!(
            shared_contact_details("BEGIN:VCARD\nTEL:+1234567\nEND:VCARD", "Shared person"),
            contact("Shared person", "+1234567", Some("1234567"))
        );
        assert_eq!(
            shared_contact_details("BEGIN:VCARD\nFN:No phone\nEND:VCARD", "Fallback"),
            None
        );
    }

    #[test]
    fn shared_contact_details_use_the_first_vcard_when_multiple_contacts_are_shared() {
        assert_eq!(
            shared_contact_details(
                "BEGIN:VCARD\nFN:Alice\nTEL:+15550101234\nEND:VCARD\nBEGIN:VCARD\nFN:Bob\nTEL:+15550105678\nEND:VCARD",
                "Several contacts",
            ),
            contact("Alice", "+15550101234", Some("15550101234"))
        );
    }
}
