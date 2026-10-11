import Compression
import CryptoKit
import Foundation

/// A Lottie sticker's file: WhatsApp's `.was`, a zip with the animation in it
/// (`animation/animation_secondary.json`, and any pictures it points at).
///
/// Unpacked by source path and content, so accounts and replacements never
/// reuse another sticker's animation or pictures.
nonisolated public enum WasArchive {
    /// The mimetype WhatsApp gives the file.
    public static let mime = "application/was"

    /// Whether a sticker's mimetype says it is a Lottie animation.
    public static func isLottie(mime: String) -> Bool {
        mime.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == Self.mime
    }

    public enum Failure: LocalizedError, Equatable {
        case notAZip
        case unsupported
        case noAnimation
        case resourceLimit

        public var errorDescription: String? {
            switch self {
            case .notAZip, .unsupported: String(localized: "This sticker's file could not be read.")
            case .noAnimation: String(localized: "This sticker has no animation.")
            case .resourceLimit: String(localized: "This sticker is too large to animate.")
            }
        }
    }

    /// Where an unpacked sticker's animation is.
    public struct Unpacked: Sendable, Equatable {
        /// The Lottie JSON.
        public let animation: URL
        /// The folder the animation's own pictures are looked up in.
        public let folder: URL
        private let lease: WasCache.Lease

        init(animation: URL, folder: URL) {
            self.animation = animation
            self.folder = folder
            lease = WasCache.Lease(folder.deletingLastPathComponent())
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.animation == rhs.animation && lhs.folder == rhs.folder
        }
    }

    /// The animation, in the order they are preferred: WhatsApp's own name
    /// for it first, then any other Lottie file in the archive.
    static let animationNames = ["animation/animation_secondary.json", "animation/animation.json"]

    /// Unpacks `file` into its own source/content folder in `cache`.
    /// The source must still exist, including on a cache hit.
    @concurrent
    public static func unpack(_ file: URL, into cache: URL) async throws -> Unpacked {
        try await gate.acquire()
        do {
            let result = try extract(file, into: cache)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private static let gate = WasExtractionGate()
    static let fileLimit = 64 * 1024 * 1024
    static let jsonLimit = 8 * 1024 * 1024

    private static func extract(_ file: URL, into cache: URL) throws -> Unpacked {
        try Task.checkCancellation()
        let files = FileManager.default
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= fileLimit else { throw Failure.resourceLimit }
        let data = try Data(contentsOf: file)
        guard data.count <= fileLimit else { throw Failure.resourceLimit }
        let source = fingerprint(Data(file.standardizedFileURL.path(percentEncoded: false).utf8))
        let folder = cache.appending(path: source, directoryHint: .isDirectory)
            .appending(path: fingerprint(data), directoryHint: .isDirectory)
        if let found = animation(in: folder) {
            try? files.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.path(percentEncoded: false))
            WasCache.trim(cache)
            return found
        }

        let bytes = [UInt8](data)
        let entries = try Zip.entries(of: bytes)
        guard !entries.isEmpty else { throw Failure.notAZip }

        // Unpacked beside the folder and moved into place, so a crash or two
        // players at once never leave half a sticker behind.
        let staging = cache.appending(path: ".unpacking-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        for entry in entries where !entry.isDirectory {
            try Task.checkCancellation()
            guard let safe = Self.safePath(entry.name) else { continue }
            let target = staging.appending(path: safe)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Zip.contents(of: entry, in: bytes).write(to: target)
        }
        guard animation(in: staging) != nil else { throw Failure.noAnimation }
        try Task.checkCancellation()
        if files.fileExists(atPath: folder.path(percentEncoded: false)) {
            try? files.removeItem(at: folder)
        }
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: staging, to: folder)
        guard let found = animation(in: folder) else { throw Failure.noAnimation }
        WasCache.trim(cache)
        return found
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The Lottie JSON in an unpacked folder, if there is one.
    static func animation(in folder: URL) -> Unpacked? {
        let files = FileManager.default
        for name in animationNames {
            let candidate = folder.appending(path: name)
            if files.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return Unpacked(animation: candidate, folder: candidate.deletingLastPathComponent())
            }
        }
        // Any other JSON under animation/, as a fallback for an archive that
        // names it differently.
        let inside = folder.appending(path: "animation", directoryHint: .isDirectory)
        let names = (try? files.contentsOfDirectory(atPath: inside.path(percentEncoded: false))) ?? []
        if let json = names.sorted().first(where: { $0.lowercased().hasSuffix(".json") }) {
            return Unpacked(animation: inside.appending(path: json), folder: inside)
        }
        return nil
    }

    /// An entry's name made safe to write under a folder: no way out of it
    /// by `..` or an absolute path, nothing hidden. Nil for a name that has
    /// nothing left.
    static func safePath(_ name: String) -> String? {
        guard !name.hasPrefix("/") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") || $0.contains("\\") }) else {
            return nil
        }
        // Resource forks and Finder litter some zip tools add.
        if parts.first == "__MACOSX" || parts.last == ".DS_Store" { return nil }
        return parts.joined(separator: "/")
    }

    /// The little of the zip format a sticker needs: the central directory,
    /// stored and deflated entries, no encryption and no zip64.
    enum Zip {
        struct Entry: Equatable {
            let name: String
            let method: UInt16
            let compressedSize: Int
            let size: Int
            let offset: Int
            var isDirectory: Bool { name.hasSuffix("/") }
        }

        /// A sticker is small; an entry that claims to be bigger than this is
        /// not one (and must not be inflated into memory).
        static let sizeLimit = 64 * 1024 * 1024

        static func entries(of bytes: [UInt8]) throws -> [Entry] {
            guard let end = endOfDirectory(in: bytes) else { throw Failure.notAZip }
            let count = Int(le16(bytes, end + 10))
            guard count <= 256 else { throw Failure.resourceLimit }
            var position = Int(le32(bytes, end + 16))
            var entries: [Entry] = []
            var total = 0
            for _ in 0..<count {
                guard position + 46 <= bytes.count, le32(bytes, position) == 0x0201_4b50 else { throw Failure.notAZip }
                let flags = le16(bytes, position + 8)
                let method = le16(bytes, position + 10)
                let compressed = Int(le32(bytes, position + 20))
                let size = Int(le32(bytes, position + 24))
                let nameLength = Int(le16(bytes, position + 28))
                let extraLength = Int(le16(bytes, position + 30))
                let commentLength = Int(le16(bytes, position + 32))
                let offset = Int(le32(bytes, position + 42))
                guard position + 46 + nameLength <= bytes.count else { throw Failure.notAZip }
                // Encrypted, or sizes that live in a zip64 record.
                if flags & 1 != 0 || compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF
                    || size > sizeLimit {
                    throw Failure.unsupported
                }
                let name = String(decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
                guard size <= fileLimit - total,
                      !name.lowercased().hasSuffix(".json") || size <= jsonLimit else { throw Failure.resourceLimit }
                total += size
                entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, offset: offset))
                position += 46 + nameLength + extraLength + commentLength
            }
            return entries
        }

        static func contents(of entry: Entry, in bytes: [UInt8]) throws -> Data {
            let header = entry.offset
            guard header + 30 <= bytes.count, le32(bytes, header) == 0x0403_4b50 else { throw Failure.notAZip }
            let start = header + 30 + Int(le16(bytes, header + 26)) + Int(le16(bytes, header + 28))
            guard start + entry.compressedSize <= bytes.count else { throw Failure.notAZip }
            let packed = Data(bytes[start..<(start + entry.compressedSize)])
            switch entry.method {
            case 0:
                guard entry.compressedSize == entry.size else { throw Failure.notAZip }
                return packed
            case 8:
                return try inflate(packed, size: entry.size)
            default:
                throw Failure.unsupported
            }
        }

        /// Raw deflate, which is what `COMPRESSION_ZLIB` reads.
        private static func inflate(_ packed: Data, size: Int) throws -> Data {
            if size == 0 { return Data() }
            guard !packed.isEmpty else { throw Failure.notAZip }
            var output = Data(count: size)
            let written = output.withUnsafeMutableBytes { destination in
                packed.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, size,
                        source.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == size else { throw Failure.notAZip }
            return output
        }

        /// The end-of-central-directory record, searched from the back past
        /// a comment of up to 64 KiB.
        private static func endOfDirectory(in bytes: [UInt8]) -> Int? {
            guard bytes.count >= 22 else { return nil }
            let lowest = max(0, bytes.count - 22 - 0xFFFF)
            var position = bytes.count - 22
            while position >= lowest {
                if le32(bytes, position) == 0x0605_4b50 { return position }
                position -= 1
            }
            return nil
        }

        private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
            UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
        }

        private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
    }
}
