//! Logs to stderr and a per-run file with upstream's filter and redaction.

use std::borrow::Cow;
use std::sync::Once;

use zapfast::paths::AppDirs;

pub fn init(dirs: &AppDirs, verbose: bool) {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let filter = if verbose {
            "info,zapfast=debug,zapfast_bridge=debug,whatsapp_rust=debug,wacore=debug"
        } else {
            "warn,zapfast=info,zapfast_bridge=info"
        };
        let result = fastframe_log::Logging::new("zapfast-mac", env!("CARGO_PKG_VERSION"))
            .filter(filter)
            .file(dirs.log_file())
            .panic_log(dirs.panic_log())
            .redact(redact_protocol)
            .init();
        if let Err(error) = result {
            eprintln!("zapfast-bridge: logging unavailable: {error}");
        }
    });
}

/// Summarises the WhatsApp library's lines, which can quote protocol
/// payloads, into fixed categories. Same rule as upstream's `main.rs`.
fn redact_protocol(record: &log::Record<'_>, message: &str) -> Option<Cow<'static, str>> {
    use zapfast::diagnostics::{is_protocol_target, protocol_summary};
    (is_protocol_target(record.target())
        || is_protocol_target(record.module_path().unwrap_or_default()))
    .then(|| protocol_summary(message))
}
