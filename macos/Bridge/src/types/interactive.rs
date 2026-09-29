use zapfast::model::{InteractiveAction, InteractiveButton, InteractiveCard, InteractiveOption};

use super::MediaInfo;

/// One choice of a single-select list.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InteractiveOptionInfo {
    pub section: String,
    pub title: String,
    pub description: String,
}

impl From<InteractiveOption> for InteractiveOptionInfo {
    fn from(option: InteractiveOption) -> Self {
        let InteractiveOption {
            section,
            title,
            description,
        } = option;
        Self {
            section,
            title,
            description,
        }
    }
}

/// What a button does here. Protocol option ids stay in the worker; a
/// reply names the button and choice by their index.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum InteractiveActionInfo {
    Unavailable,
    /// A quick reply: sends a response quoting the message.
    Reply,
    /// Copies a code, locally.
    Copy {
        code: String,
    },
    /// Opens a list of choices; picking one sends a response.
    Select {
        options: Vec<InteractiveOptionInfo>,
    },
}

impl From<InteractiveAction> for InteractiveActionInfo {
    fn from(action: InteractiveAction) -> Self {
        match action {
            InteractiveAction::Unavailable => Self::Unavailable,
            InteractiveAction::Reply => Self::Reply,
            InteractiveAction::Copy(code) => Self::Copy { code },
            InteractiveAction::Select(options) => Self::Select {
                options: options.into_iter().map(Into::into).collect(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InteractiveButtonInfo {
    pub label: String,
    /// A validated HTTP(S) link, opened in the browser.
    pub url: Option<String>,
    pub action: InteractiveActionInfo,
}

impl From<InteractiveButton> for InteractiveButtonInfo {
    fn from(button: InteractiveButton) -> Self {
        let InteractiveButton { label, url, action } = button;
        Self {
            label,
            url,
            action: action.into(),
        }
    }
}

/// One card of a carousel: its own image and buttons.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CarouselCardInfo {
    pub body: String,
    pub buttons: Vec<InteractiveButtonInfo>,
    pub image: Option<MediaInfo>,
    pub needs_phone: bool,
    pub thumbnail: Option<Vec<u8>>,
}

/// Buttons, lists and cards of a business message.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InteractiveCardInfo {
    /// Message text without the action labels.
    pub body: String,
    pub buttons: Vec<InteractiveButtonInfo>,
    pub image: Option<MediaInfo>,
    /// Parts only WhatsApp Web or the phone can show.
    pub needs_phone: bool,
    /// Carousel cards in order; downloads name them by index.
    pub carousel: Vec<CarouselCardInfo>,
    pub thumbnail: Option<Vec<u8>>,
}

fn buttons(list: Vec<InteractiveButton>) -> Vec<InteractiveButtonInfo> {
    list.into_iter().map(Into::into).collect()
}

impl From<InteractiveCard> for InteractiveCardInfo {
    fn from(card: InteractiveCard) -> Self {
        let InteractiveCard {
            body,
            buttons: list,
            image,
            needs_phone,
            carousel,
            thumbnail,
        } = card;
        Self {
            body,
            buttons: buttons(list),
            image: image.map(Into::into),
            needs_phone,
            carousel: carousel
                .into_iter()
                .map(|card| {
                    // Carousels do not nest: a card's own carousel is empty.
                    let InteractiveCard {
                        body,
                        buttons: list,
                        image,
                        needs_phone,
                        carousel: _,
                        thumbnail,
                    } = card;
                    CarouselCardInfo {
                        body,
                        buttons: buttons(list),
                        image: image.map(Into::into),
                        needs_phone,
                        thumbnail,
                    }
                })
                .collect(),
            thumbnail,
        }
    }
}
