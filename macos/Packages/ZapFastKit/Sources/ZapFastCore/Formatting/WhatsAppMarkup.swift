import Foundation
import ZapFastBridge

/// WhatsApp's text markup as an `AttributedString`: `*bold*`, `_italic_`,
/// `~strikethrough~`, ```` ```monospace``` ````, `` `inline code` ``, links,
/// and `@number` mentions resolved to names. Styles do not nest, which is
/// how the phone renders them too in practice.
public enum WhatsAppMarkup {
    public struct Style: Sendable {
        public var mentionColor: AttributeContainer

        public init(mentionColor: AttributeContainer = AttributeContainer()) {
            self.mentionColor = mentionColor
        }
    }

    public static func attributed(
        _ text: String,
        mentions: [MentionInfo] = [],
        name: (String) -> String = { $0 },
        style: Style = Style()
    ) -> AttributedString {
        let resolved = resolveMentions(text, mentions: mentions, name: name)
        var output = AttributedString()
        let source = resolved.text as NSString
        var cursor = 0

        for match in pattern.matches(in: resolved.text, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > cursor {
                output += plain(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            output += styled(match, in: source)
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            output += plain(source.substring(from: cursor))
        }

        applyLinks(to: &output)
        applyMentions(resolved.names, to: &output, style: style)
        return output
    }

    /// The text with `@number` mentions shown as `@name`, markup left as
    /// typed, for copying.
    public static func resolvingMentions(
        _ text: String,
        mentions: [MentionInfo],
        name: (String) -> String
    ) -> String {
        resolveMentions(text, mentions: mentions, name: name).text
    }

    // MARK: Markup

    /// Code blocks first, then inline code, then a single-character style
    /// whose delimiters hug non-space text at word boundaries.
    private static let pattern = try! NSRegularExpression(
        pattern: #"```([\s\S]+?)```|`([^`\n]+)`|(?<![\p{L}\p{N}])([*_~])(?=\S)(.+?)(?<=\S)\3(?![\p{L}\p{N}])"#,
        options: []
    )

    private static func styled(_ match: NSTextCheckingResult, in source: NSString) -> AttributedString {
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        if let block = group(1) ?? group(2) {
            var part = AttributedString(block)
            part.inlinePresentationIntent = .code
            return part
        }
        guard let marker = group(3), let body = group(4) else {
            return plain(source.substring(with: match.range))
        }
        var part = AttributedString(body)
        switch marker {
        case "*": part.inlinePresentationIntent = .stronglyEmphasized
        case "_": part.inlinePresentationIntent = .emphasized
        case "~": part.inlinePresentationIntent = .strikethrough
        default: break
        }
        return part
    }

    private static func plain(_ text: String) -> AttributedString {
        AttributedString(text)
    }

    // MARK: Links

    private static let detector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )

    private static func applyLinks(to output: inout AttributedString) {
        let text = String(output.characters)
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: output),
                  let upper = AttributedString.Index(range.upperBound, within: output) else { continue }
            let url: URL? = switch match.resultType {
            case .link: match.url
            case .phoneNumber: match.phoneNumber.flatMap { URL(string: "tel:\($0.filter { !$0.isWhitespace })") }
            default: nil
            }
            if let url {
                output[lower..<upper].link = url
            }
        }
    }

    // MARK: Mentions

    private struct Resolved {
        var text: String
        /// The visible `@Name` strings that stand for mentions.
        var names: [String]
    }

    private static func resolveMentions(
        _ text: String,
        mentions: [MentionInfo],
        name: (String) -> String
    ) -> Resolved {
        var text = text
        var names: [String] = []
        for mention in mentions {
            let token = "@\(mention.user)"
            guard text.contains(token) else { continue }
            let visible = "@\(name(mention.id))"
            text = text.replacingOccurrences(of: token, with: visible)
            names.append(visible)
        }
        return Resolved(text: text, names: names)
    }

    private static func applyMentions(_ names: [String], to output: inout AttributedString, style: Style) {
        for name in Set(names) {
            var searchStart = output.startIndex
            while searchStart < output.endIndex,
                  let range = output[searchStart...].range(of: name) {
                output[range].mergeAttributes(style.mentionColor)
                output[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
    }
}
