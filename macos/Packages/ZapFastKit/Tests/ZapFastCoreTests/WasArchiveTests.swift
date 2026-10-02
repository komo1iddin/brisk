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

        // Done once: the file itself is not needed again.
        try FileManager.default.removeItem(at: was)
        #expect(try await WasArchive.unpack(was, into: cache) == unpacked)
        // No staging folder is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))
        #expect(left == ["chat-id.was"])
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
}
