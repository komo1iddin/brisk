import ZapFastBridge

/// What a message only the phone can show says in its place: a view-once
/// photo, video or voice message says what it is (upstream's wording),
/// since WhatsApp never lets a linked device open it.
enum PhoneOnlyText {
    static func text(viewOnce: Bool, liveLocation: Bool, once: OnceMediaKind?) -> String {
        switch once {
        case .photo:
            String(localized: "View once photo. For your privacy, it opens only on your phone.")
        case .video:
            String(localized: "View once video. For your privacy, it opens only on your phone.")
        case .voice:
            String(localized: "View once voice message. For your privacy, it opens only on your phone.")
        case .audio:
            String(localized: "View once audio. For your privacy, it opens only on your phone.")
        case nil:
            if viewOnce {
                String(localized: "View once message. For your privacy, it opens only on your phone.")
            } else if liveLocation {
                String(localized: "Live location. See it on your phone.")
            } else {
                String(localized: "This message is only on your phone.")
            }
        }
    }
}
