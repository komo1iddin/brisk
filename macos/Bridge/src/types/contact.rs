use zapfast::model::Contact;

/// Names known for one account, from the address book and push names.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ContactRecord {
    pub id: String,
    /// Address-book name.
    pub full_name: Option<String>,
    /// Address-book first name, when saved separately.
    pub first_name: Option<String>,
    /// The name the person set for themselves.
    pub push_name: Option<String>,
}

impl From<Contact> for ContactRecord {
    fn from(contact: Contact) -> Self {
        let Contact {
            id,
            full_name,
            first_name,
            push_name,
        } = contact;
        Self {
            id,
            full_name,
            first_name,
            push_name,
        }
    }
}
