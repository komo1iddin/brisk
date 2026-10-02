import Foundation

/// Writes an export to disk: a folder with the conversation's pages and, when
/// media was asked for, the attachments in folders by kind. Everything here
/// is file work, so it runs off the main actor.
nonisolated enum ChatExportWriter {
    /// How many messages one page holds.
    static let pageSize = 1000

    /// Writes `entries`, oldest first, as a new folder inside `parent`. The
    /// folder is named after the chat and never replaces one that is there:
    /// a later export of the same chat gets a number. A failure leaves no
    /// half-written folder behind.
    @concurrent
    static func write(
        _ entries: [ChatExportEntry],
        title: String,
        includeMedia: Bool,
        into parent: URL,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: Date = .now,
        pageSize: Int = ChatExportWriter.pageSize
    ) async throws -> ChatExportSummary {
        let files = FileManager.default
        let folder = unusedFolder(named: ChatExport.suggestedFolderName(chat: title), in: parent)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        var finished = false
        defer { if !finished { try? files.removeItem(at: folder) } }

        var names = FileNames(timeZone: timeZone)
        var attachments = 0
        var missing = 0
        var placed: [ChatExportHTML.Placed] = []
        placed.reserveCapacity(entries.count)
        for entry in entries {
            try Task.checkCancellation()
            guard case let .media(kind, source, name, _, _, _, _) = entry.body, includeMedia else {
                placed.append(.init(entry: entry, file: nil))
                continue
            }
            guard let source, files.isReadableFile(atPath: source.path(percentEncoded: false)) else {
                missing += 1
                placed.append(.init(entry: entry, file: nil))
                continue
            }
            let relative = names.next(kind: kind, timestamp: entry.timestamp, source: source, original: name)
            do {
                let target = folder.appending(path: relative)
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: source, to: target)
                attachments += 1
                placed.append(.init(entry: entry, file: relative))
            } catch {
                missing += 1
                placed.append(.init(entry: entry, file: nil))
            }
        }

        let pages = max(1, (placed.count + pageSize - 1) / pageSize)
        let exported = now.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale))
        let language = locale.language.languageCode?.identifier ?? "en"
        // Who is in it: in the order they first wrote.
        var participants: [String] = []
        for entry in entries where !participants.contains(entry.author) { participants.append(entry.author) }
        for number in 1...pages {
            try Task.checkCancellation()
            let items = Array(placed[min(placed.count, (number - 1) * pageSize)..<min(placed.count, number * pageSize)])
            let html = ChatExportHTML.render(.init(
                title: title, participants: participants, firstDay: entries.first?.day, lastDay: entries.last?.day,
                number: number, pages: pages, messages: placed.count, exported: exported, language: language, items: items
            ))
            try html.write(to: folder.appending(path: ChatExportHTML.fileName(page: number)), atomically: false, encoding: .utf8)
        }
        finished = true
        return ChatExportSummary(
            folder: folder, page: folder.appending(path: ChatExportHTML.fileName(page: 1)),
            messages: entries.count, attachments: attachments, missingMedia: missing
        )
    }

    /// `name`, or `name 2`, `name 3`, ... for the first that is not there.
    static func unusedFolder(named name: String, in parent: URL) -> URL {
        let files = FileManager.default
        var candidate = parent.appending(path: name, directoryHint: .isDirectory)
        var copy = 1
        while files.fileExists(atPath: candidate.path(percentEncoded: false)) {
            copy += 1
            candidate = parent.appending(path: "\(name) \(copy)", directoryHint: .isDirectory)
        }
        return candidate
    }

    /// Gives each attachment a path no other has, in the folder of its kind:
    /// `photos/photo_12@2026-09-30_22-15-09.jpg`, and a document keeps the name
    /// it was sent with, `files/Report.pdf`.
    struct FileNames {
        private var counts: [ChatExportMediaKind: Int] = [:]
        private var used: Set<String> = []
        private let stamp: DateFormatter

        init(timeZone: TimeZone) {
            stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.timeZone = timeZone
            stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        }

        mutating func next(kind: ChatExportMediaKind, timestamp: Int64, source: URL, original: String?) -> String {
            counts[kind, default: 0] += 1
            let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let name: String
            if kind == .document, let original, let own = Self.documentName(original) {
                name = own
            } else {
                let time = stamp.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
                name = "\(kind.word)_\(counts[kind] ?? 1)@\(time).\(ext)"
            }
            return "\(kind.folder)/\(unique(name, in: kind.folder))"
        }

        /// A name not used yet in its folder: "report.pdf", "report (2).pdf", ...
        private mutating func unique(_ name: String, in folder: String) -> String {
            var candidate = name
            var copy = 1
            while used.contains("\(folder)/\(candidate)".lowercased()) {
                copy += 1
                let file = name as NSString
                let base = file.deletingPathExtension
                candidate = file.pathExtension.isEmpty
                    ? "\(base) (\(copy))"
                    : "\(base) (\(copy)).\(file.pathExtension)"
            }
            used.insert("\(folder)/\(candidate)".lowercased())
            return candidate
        }

        /// A document's own name, if it is fit to use on every file system;
        /// nil for one that is not, so it gets a numbered name instead.
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
