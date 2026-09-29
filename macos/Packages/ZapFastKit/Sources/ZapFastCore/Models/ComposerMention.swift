import Foundation

/// A group member picked from the composer's `@` suggestions. The composer
/// shows `@name`; sending turns it into WhatsApp's `@user` token.
public struct ComposerMention: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A member offered while typing `@` in a group.
public struct MentionCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Formatted phone number, when the id carries one.
    public let phone: String?
}

/// Upstream's mention wire rules (src/app.rs `encode_composer_mentions`,
/// `contains_mention_token`, `find_named_mention`).
enum MentionEncoding {
    /// Replaces each picked `@name` still in `text` with its `@user` token
    /// and returns the ids to mention: picked members first, then members
    /// whose token the text already holds (an edited message's mentions).
    /// Picks of people no longer in `participants` are dropped.
    static func encode(
        _ text: String,
        picked: [ComposerMention],
        participants: [String]
    ) -> (text: String, ids: [String]) {
        var text = text
        var ids: [String] = []
        for mention in picked where participants.contains(mention.id) {
            guard let user = user(of: mention.id) else { continue }
            if let range = namedMention(in: text, token: "@\(mention.name)") {
                text.replaceSubrange(range, with: "@\(user)")
                if !ids.contains(mention.id) { ids.append(mention.id) }
            }
        }
        for id in participants {
            guard let user = user(of: id) else { continue }
            if containsToken(text, user: user), !ids.contains(id) { ids.append(id) }
        }
        return (text, ids)
    }

    /// `@user` not followed by another digit, so `@1` is not found in `@12`.
    static func containsToken(_ text: String, user: String) -> Bool {
        let token = "@\(user)"
        var rest = text[...]
        while let range = rest.range(of: token) {
            let after = rest[range.upperBound...].first
            if after.map({ !($0.isASCII && $0.isNumber) }) ?? true { return true }
            rest = rest[rest.index(after: range.lowerBound)...]
        }
        return false
    }

    /// The first `@name` not running on into another word.
    static func namedMention(in text: String, token: String) -> Range<String.Index>? {
        var searchFrom = text.startIndex
        while let range = text.range(of: token, range: searchFrom..<text.endIndex) {
            let after = text[range.upperBound...].first
            if after.map({ !($0.isLetter || $0.isNumber) }) ?? true { return range }
            searchFrom = text.index(after: range.lowerBound)
        }
        return nil
    }

    static func user(of id: String) -> String? {
        let user = id.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        return user.flatMap { $0.isEmpty ? nil : $0 }
    }
}
