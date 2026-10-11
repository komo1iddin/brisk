# Draft upstream license clarification question

Not sent. No upstream source or dependency license has been changed here.

At whatsapp-rust revision `f7468ae2920a2b0aedbd0848cf121de56a07f93c`,
[wacore/libsignal/Cargo.toml](https://github.com/oxidezap/whatsapp-rust/blob/f7468ae2920a2b0aedbd0848cf121de56a07f93c/wacore/libsignal/Cargo.toml)
declares `license = "MIT"`. Signal source headers, for example
[session_cipher.rs](https://github.com/oxidezap/whatsapp-rust/blob/f7468ae2920a2b0aedbd0848cf121de56a07f93c/wacore/libsignal/src/protocol/session_cipher.rs),
declare `SPDX-License-Identifier: AGPL-3.0-only` and name Signal Messenger, LLC.
The native ZapFast bridge includes this crate through whatsapp-rust.

Could you clarify which terms govern these files and binary redistribution
at this revision, with the relevant license grant or provenance? If the
manifest is inaccurate, could the package include the correct declaration
and full license/notice texts? We are preserving the existing declarations
and keeping our binary release review pending rather than changing them
in the downstream repository.

Our native dependency inventory also flags packages whose published source
archives carry no full license text. Those need a separate redistribution
review before the native binary is published.
