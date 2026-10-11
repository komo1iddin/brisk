import Foundation
import Testing
@testable import ZapFastCore

@MainActor
struct WasArchiveTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-was-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A zip of a folder's contents, deflated, made by the system's own tool.
    private func zip(_ folder: URL, as name: String, in directory: URL) throws -> URL {
        let archive = directory.appending(path: name)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn",
                             folder.path(percentEncoded: false), archive.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return archive
    }

    /// A zip of entries stored without compression, written by hand, for
    /// names the system's tool would refuse to write.
    private func storedZip(_ entries: [(String, String)]) -> Data {
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF) }
        var body: [UInt8] = []
        var directory: [UInt8] = []
        for (name, text) in entries {
            let name = Array(name.utf8)
            let content = Array(text.utf8)
            let offset = body.count
            body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(content.count) + le32(content.count) + le16(name.count) + le16(0) + name + content
            directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(content.count) + le32(content.count) + le16(name.count) + le16(0) + le16(0)
                + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(directory.count) + le32(body.count) + le16(0)
        return Data(body + directory + end)
    }

    @Test func theAnimationAndItsPicturesAreUnpackedOnceAndKept() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try write("{\"v\":\"5\"}", to: source.appending(path: "animation/animation_secondary.json"))
        try write("png", to: source.appending(path: "animation/images/a.png"))
        let was = try zip(source, as: "chat-id.was", in: root)
        let cache = root.appending(path: "cache")

        let unpacked = try await WasArchive.unpack(was, into: cache)
        #expect(unpacked.animation.lastPathComponent == "animation_secondary.json")
        #expect(try String(contentsOf: unpacked.animation, encoding: .utf8) == "{\"v\":\"5\"}")
        #expect(try String(contentsOf: unpacked.folder.appending(path: "images/a.png"), encoding: .utf8) == "png")

        // An unchanged source reuses the same unpacked content.
        #expect(try await WasArchive.unpack(was, into: cache) == unpacked)
        // No staging folder is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))
        #expect(left.count == 1)
        #expect(!left.contains(where: { $0.hasPrefix(".unpacking-") }))
        // Removed account/source files must not be resurrected from a cache.
        try FileManager.default.removeItem(at: was)
        await #expect(throws: (any Error).self) { try await WasArchive.unpack(was, into: cache) }
    }

    @Test func matchingFilenamesInDifferentAccountsAndReplacementsStaySeparate() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "cache")
        let a = root.appending(path: "account-a/same.was")
        let b = root.appending(path: "account-b/same.was")
        try FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try storedZip([("animation/animation.json", "account-a")]).write(to: a)
        try storedZip([("animation/animation.json", "account-b")]).write(to: b)
        let first = try await WasArchive.unpack(a, into: cache)
        let second = try await WasArchive.unpack(b, into: cache)
        #expect(first.folder != second.folder)
        #expect(try String(contentsOf: second.animation, encoding: .utf8) == "account-b")
        try storedZip([("animation/animation.json", "replacement")]).write(to: a)
        let replaced = try await WasArchive.unpack(a, into: cache)
        #expect(replaced.folder != first.folder)
        #expect(try String(contentsOf: replaced.animation, encoding: .utf8) == "replacement")
        try FileManager.default.removeItem(at: a.deletingLastPathComponent())
        await #expect(throws: (any Error).self) { try await WasArchive.unpack(a, into: cache) }
        #expect(try await WasArchive.unpack(b, into: cache) == second)
    }

    @Test func anotherNamedAnimationWillDo() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "other.was")
        try storedZip([("animation/moving.json", "{}"), ("readme.txt", "x")]).write(to: was)
        let unpacked = try await WasArchive.unpack(was, into: root.appending(path: "cache"))
        #expect(unpacked.animation.lastPathComponent == "moving.json")
    }

    @Test func theSecondaryAnimationIsPreferred() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "both.was")
        try storedZip([("animation/animation.json", "1"), ("animation/animation_secondary.json", "2")]).write(to: was)
        let unpacked = try await WasArchive.unpack(was, into: root.appending(path: "cache"))
        #expect(try String(contentsOf: unpacked.animation, encoding: .utf8) == "2")
    }

    @Test func anArchiveWithoutAnimationLeavesNothingBehind() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "empty.was")
        try storedZip([("readme.txt", "x")]).write(to: was)
        let cache = root.appending(path: "cache")
        await #expect(throws: WasArchive.Failure.noAnimation) { try await WasArchive.unpack(was, into: cache) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))) ?? []
        #expect(left.isEmpty)
    }

    @Test func somethingThatIsNotAZipIsSaidSo() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "plain.was")
        try Data("RIFF....WEBP".utf8).write(to: was)
        await #expect(throws: WasArchive.Failure.notAZip) {
            try await WasArchive.unpack(was, into: root.appending(path: "cache"))
        }
    }

    @Test func aNameThatLeadsOutOfTheFolderIsNeverWritten() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "evil.was")
        try storedZip([
            ("../escaped.txt", "no"), ("/etc/absolute.txt", "no"), ("animation/../up.txt", "no"),
            ("animation/animation.json", "{}"),
        ]).write(to: was)
        let cache = root.appending(path: "cache")
        let unpacked = try await WasArchive.unpack(was, into: cache)
        #expect(unpacked.animation.lastPathComponent == "animation.json")
        for escaped in ["escaped.txt", "up.txt", "cache/escaped.txt", "cache/up.txt"] {
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: escaped).path(percentEncoded: false)))
        }
        let inside = unpacked.folder.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: inside.path(percentEncoded: false))
        #expect(names == ["animation"])
    }

    @Test func safePathsKeepToTheFolder() {
        #expect(WasArchive.safePath("animation/a.json") == "animation/a.json")
        #expect(WasArchive.safePath("a//b") == "a/b")
        #expect(WasArchive.safePath("../x") == nil)
        #expect(WasArchive.safePath("a/../x") == nil)
        #expect(WasArchive.safePath("a\\b") == nil)
        #expect(WasArchive.safePath("__MACOSX/x") == nil)
        #expect(WasArchive.safePath("dir/.DS_Store") == nil)
        #expect(WasArchive.safePath("/") == nil)
        #expect(WasArchive.safePath("/etc/passwd") == nil)
    }

    @Test func tooManyEntriesAreRejectedBeforeExtraction() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "many.was")
        try storedZip((0..<257).map { ("animation/\($0).json", "{}") }).write(to: was)
        let cache = root.appending(path: "cache")
        await #expect(throws: WasArchive.Failure.resourceLimit) { try await WasArchive.unpack(was, into: cache) }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test(arguments: [true, false])
    func advertisedJsonAndAggregateSizesAreRejectedWithoutAllocatingThem(json: Bool) async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "large.was")
        var bytes = [UInt8](storedZip([(json ? "animation/a.json" : "animation/a.png", "a"), ("animation/b.png", "b")]))
        let size = json ? WasArchive.jsonLimit + 1 : 40 * 1024 * 1024
        for index in 0..<(bytes.count - 28) where Array(bytes[index..<(index + 4)]) == [0x50, 0x4b, 0x01, 0x02] {
            for byte in 0..<4 { bytes[index + 24 + byte] = UInt8((size >> (byte * 8)) & 255) }
        }
        try Data(bytes).write(to: was)
        await #expect(throws: WasArchive.Failure.resourceLimit) { try await WasArchive.unpack(was, into: root.appending(path: "cache")) }
    }

    @Test func aSparseOversizeSourceIsRejectedBeforeReading() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "large.was")
        try Data().write(to: was)
        let file = try FileHandle(forWritingTo: was)
        try file.truncate(atOffset: UInt64(WasArchive.fileLimit + 1))
        try file.close()
        await #expect(throws: WasArchive.Failure.resourceLimit) { try await WasArchive.unpack(was, into: root.appending(path: "cache")) }
    }

    @Test func cachePruningPreservesActiveResourcesAndUnrelatedFiles() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let was = root.appending(path: "sticker.was")
        let cache = root.appending(path: "cache")
        try storedZip([("animation/animation.json", "{}")]).write(to: was)
        var unpacked: WasArchive.Unpacked? = try await WasArchive.unpack(was, into: cache)
        let animation = try #require(unpacked?.animation)
        let unrelated = cache.appending(path: "unrelated/keep.txt")
        try write("fixture", to: unrelated)
        withExtendedLifetime(unpacked) {
            WasCache.trim(cache, bytes: 0, count: 0)
            #expect(FileManager.default.fileExists(atPath: animation.path))
        }
        unpacked = nil
        WasCache.trim(cache, bytes: 0, count: 0)
        #expect(!FileManager.default.fileExists(atPath: animation.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: was.path))
    }

    @Test func aCancelledExtractionWaiterDoesNotBlockTheNextReader() async throws {
        let gate = WasExtractionGate()
        try await gate.acquire()
        let waiting = Task { try await gate.acquire(); await gate.release() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    @Test(arguments: [UInt16(0), UInt16(8)])
    func emptyPackedDataCannotSatisfyANonemptyEntry(method: UInt16) {
        let header: [UInt8] = [0x50, 0x4b, 0x03, 0x04] + Array(repeating: 0, count: 26)
        let entry = WasArchive.Zip.Entry(name: "a", method: method, compressedSize: 0, size: 1, offset: 0)
        #expect(throws: WasArchive.Failure.notAZip) { try WasArchive.Zip.contents(of: entry, in: header) }
    }
}
