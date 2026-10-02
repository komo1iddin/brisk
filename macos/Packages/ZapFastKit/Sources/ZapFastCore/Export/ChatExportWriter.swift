import Foundation

/// What a message is in an exported chat.
nonisolated enum ChatExportBody: Sendable, Equatable {
    /// Text that stands as it is.
    case text(String)
    /// An attachment: written beside the text when it is downloaded and
    /// media was asked for, and named by a placeholder otherwise.
    case media(kind: ChatExportMediaKind, source: URL?, name: String?, caption: String)
}

nonisolated enum ChatExportMediaKind: Sendable, Equatable {
    case photo, video, audio, sticker, document

    /// The word WhatsApp's own export puts in an attachment's file name.
    var word: String {
        switch self {
        case .photo: "PHOTO"
        case .video: "VIDEO"
        case .audio: "AUDIO"
        case .sticker: "STICKER"
        case .document: "DOCUMENT"
        }
    }
}

/// One message of an export, with the pieces that depend on the reader's
/// language already written.
nonisolated struct ChatExportEntry: Sendable, Equatable {
    let timestamp: Int64
    /// "30/09/2026, 09:28:15", without the brackets.
    let stamp: String
    let author: String
    let body: ChatExportBody
}

nonisolated public struct ChatExportSummary: Sendable, Equatable {
    /// The file written: a `.zip` with media, a `.txt` without.
    public let url: URL
    public let messages: Int
    /// Attachments written beside the text.
    public let attachments: Int
    /// Attachments left out because they were never downloaded or could
    /// not be copied (only counted when media was asked for).
    public let missingMedia: Int
}

/// Writes an export to disk. Everything here is file work, so it runs off
/// the main actor.
nonisolated enum ChatExportWriter {
    enum Failure: LocalizedError {
        case compressionFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .compressionFailed:
                String(localized: "The chat could not be compressed.")
            }
        }
    }

    /// The text file's name inside the zip, as WhatsApp's own export has it.
    static let textFileName = "_chat.txt"

    /// Writes `entries`, oldest first, to `destination`: the text alone, or
    /// a zip of the text and the attachments.
    @concurrent
    static func write(
        _ entries: [ChatExportEntry],
        includeMedia: Bool,
        to destination: URL,
        timeZone: TimeZone = .autoupdatingCurrent
    ) async throws -> ChatExportSummary {
        let files = FileManager.default
        let staging = files.temporaryDirectory.appending(path: "zapfast-export-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        var lines: [String] = []
        lines.reserveCapacity(entries.count)
        var names = FileNames(timeZone: timeZone)
        var attachments = 0
        var missing = 0
        for entry in entries {
            try Task.checkCancellation()
            let prefix = "[\(entry.stamp)] \(entry.author): "
            switch entry.body {
            case .text(let text):
                lines.append(prefix + text)
            case let .media(kind, source, name, caption):
                var marker = String(localized: "<Media omitted>")
                if includeMedia {
                    if let source, files.isReadableFile(atPath: source.path(percentEncoded: false)) {
                        let file = names.next(kind: kind, timestamp: entry.timestamp, source: source, original: name)
                        do {
                            try files.copyItem(at: source, to: staging.appending(path: file))
                            marker = String(localized: "<attached: \(file)>")
                            attachments += 1
                        } catch {
                            missing += 1
                        }
                    } else {
                        missing += 1
                    }
                }
                lines.append(prefix + marker + (caption.isEmpty ? "" : "\n" + caption))
            }
        }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")

        if includeMedia {
            try text.write(to: staging.appending(path: textFileName), atomically: false, encoding: .utf8)
            let archive = files.temporaryDirectory.appending(path: "zapfast-export-\(UUID().uuidString).zip")
            defer { try? files.removeItem(at: archive) }
            try compress(staging, into: archive)
            try place(archive, at: destination)
        } else {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        }
        return ChatExportSummary(
            url: destination, messages: entries.count, attachments: attachments, missingMedia: missing
        )
    }

    /// Zips a folder's contents (not the folder itself) with `ditto`, which
    /// writes archives that Finder, Archive Utility and `unzip` all open.
    private static func compress(_ folder: URL, into archive: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--norsrc", "--noextattr", "--noqtn",
            folder.path(percentEncoded: false), archive.path(percentEncoded: false),
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.compressionFailed(process.terminationStatus) }
    }

    /// Moves a finished file into place, replacing one the person chose to
    /// replace.
    private static func place(_ finished: URL, at destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try files.replaceItemAt(destination, withItemAt: finished)
        } else {
            try files.moveItem(at: finished, to: destination)
        }
    }

    /// Gives each attachment a file name no other has: in the numbered
    /// style of WhatsApp's own export, `00000012-PHOTO-2026-09-30-09-28-15.jpg`,
    /// and a document keeps the name it was sent with.
    struct FileNames {
        private var sequence = 0
        private var used: Set<String> = []
        private let stamp: DateFormatter

        init(timeZone: TimeZone) {
            stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.timeZone = timeZone
            stamp.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        }

        mutating func next(kind: ChatExportMediaKind, timestamp: Int64, source: URL, original: String?) -> String {
            sequence += 1
            let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let wanted: String
            if kind == .document, let original, let own = Self.documentName(original) {
                wanted = own
            } else {
                let time = stamp.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
                wanted = String(format: "%08d-%@-%@.%@", sequence, kind.word, time, ext)
            }
            return unique(wanted)
        }

        /// A name not used yet: "report.pdf", "report (2).pdf", ...
        private mutating func unique(_ name: String) -> String {
            var candidate = name
            var copy = 1
            while used.contains(candidate.lowercased()) {
                copy += 1
                let file = name as NSString
                let base = file.deletingPathExtension
                candidate = file.pathExtension.isEmpty
                    ? "\(base) (\(copy))"
                    : "\(base) (\(copy)).\(file.pathExtension)"
            }
            used.insert(candidate.lowercased())
            return candidate
        }

        /// A document's own name, if it is fit to use inside a zip and on
        /// every file system; nil for one that is not, so it gets a numbered
        /// name instead.
        static func documentName(_ name: String) -> String? {
            let unsafe = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
            let cleaned = name.unicodeScalars
                .map { unsafe.contains($0) ? "-" : String($0) }
                .joined()
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", cleaned.utf8.count <= 200 else { return nil }
            return cleaned
        }
    }
}
