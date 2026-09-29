import ZapFastBridge

extension ChatSummary {
    /// Upstream's `can_edit_info`: any member while the group's info is
    /// open, only admins once it is locked, nothing until that is known or
    /// after leaving.
    public var canEditInfo: Bool {
        kind == .group && !left && (admin || infoLocked == false)
    }

    /// Upstream's `can_send`: not locked, read-only, left, or a broadcast.
    public var canSend: Bool {
        !locked && !readOnly && !left && kind != .broadcast
    }

    /// Upstream's `can_leave`. `ours` holds every id we may be listed
    /// under; no known id, or no member list yet, still offers it.
    public func canLeave(ours: [String]) -> Bool {
        if left { return false }
        if isChannel { return !readOnly }
        guard kind == .group else { return false }
        return ours.isEmpty || participants.isEmpty || participants.contains(where: ours.contains)
    }
}

/// Upstream's `compose_name`: a full name from first and last, and the
/// first name alone as the short one. Nil when both are blank.
public enum ContactName {
    public static func compose(first: String, last: String) -> (full: String, short: String?)? {
        let first = first.trimmingCharacters(in: .whitespaces)
        let last = last.trimmingCharacters(in: .whitespaces)
        if first.isEmpty, last.isEmpty { return nil }
        let full = last.isEmpty ? first : first.isEmpty ? last : "\(first) \(last)"
        return (full, first.isEmpty ? nil : first)
    }
}
