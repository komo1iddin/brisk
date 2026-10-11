import AppKit
import Foundation
import Testing
import ZapFastDesign
@testable import ZapFastCore

@MainActor
struct AuditCacheIsolationTests {
    private func png(_ rgba: [UInt8]) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<2 { for x in 0..<2 {
            let offset = y * bitmap.bytesPerRow + x * 4
            for component in 0..<4 { bytes[offset + component] = rgba[component] }
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func replacingThumbnailBytesUnderOneMessageKeyShowsTheNewImage() async throws {
        let key = "audit-thumbnail-\(UUID().uuidString)"
        let first = try #require(await Thumbnails.load(png([255, 0, 0, 255]), key: key, points: 2))
        let second = try #require(await Thumbnails.load(png([0, 0, 255, 255]), key: key, points: 2))
        #expect(first !== second)
    }

    @Test func stickersWithTheSameFilenameInTwoAccountsStaySeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeArchive(_ account: String, text: String) throws -> URL {
            let folder = root.appending(path: account)
            let source = folder.appending(path: "source/animation")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: source.appending(path: "animation.json"))
            let archive = folder.appending(path: "same-message.was")
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn",
                                 source.deletingLastPathComponent().path, archive.path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return archive
        }
        let a = try makeArchive("account-a", text: "{\"audit\":\"a\"}")
        let b = try makeArchive("account-b", text: "{\"audit\":\"b\"}")
        let cache = root.appending(path: "shared-lottie-cache")
        _ = try await WasArchive.unpack(a, into: cache)
        let unpacked = try await WasArchive.unpack(b, into: cache)
        #expect(try String(contentsOf: unpacked.animation, encoding: .utf8) == "{\"audit\":\"b\"}")
    }
}
