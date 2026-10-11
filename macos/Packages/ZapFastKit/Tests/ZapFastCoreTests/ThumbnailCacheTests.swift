import AppKit
import Foundation
import Testing
import ZapFastDesign

@MainActor
struct ThumbnailCacheTests {
    private func png(_ rgb: (UInt8, UInt8, UInt8)) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<8 { for x in 0..<8 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = rgb.0; pixels[offset + 1] = rgb.1
            pixels[offset + 2] = rgb.2; pixels[offset + 3] = 255
        } }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func changedBytesReplaceThePreviewWithoutAliasingItsCacheEntry() async throws {
        let key = UUID().uuidString
        let red = try png((255, 0, 0)), blue = try png((0, 0, 255))
        #expect(red != blue)
        let first = try #require(await Thumbnails.load(red, key: key, points: 2))
        #expect(Thumbnails.cached(blue, key: key, points: 2) == nil)
        let second = try #require(await Thumbnails.load(blue, key: key, points: 2))
        #expect(first !== second)
        #expect(Thumbnails.cached(red, key: key, points: 2) === first)
        #expect(Thumbnails.cached(blue, key: key, points: 2) === second)
    }

    @Test func accountsAndChatsWithMatchingMessageIDsHaveIndependentEntries() async throws {
        let bytes = try png((255, 0, 0))
        let id = UUID().uuidString
        let a = Thumbnails.scope(["account-a", "chat-a", "thumb", id])
        let b = Thumbnails.scope(["account-b", "chat-a", "thumb", id])
        let c = Thumbnails.scope(["account-a", "chat-b", "thumb", id])
        let first = try #require(await Thumbnails.load(bytes, key: a, points: 2))
        #expect(Thumbnails.cached(bytes, key: b, points: 2) == nil)
        let otherAccount = try #require(await Thumbnails.load(bytes, key: b, points: 2))
        let otherChat = try #require(await Thumbnails.load(bytes, key: c, points: 2))
        #expect(first !== otherAccount)
        #expect(first !== otherChat)
        #expect(await Thumbnails.load(bytes, key: a, points: 2) === first)
    }

    @Test func namespacesCannotCollideAtComponentBoundaries() {
        #expect(Thumbnails.scope(["a-b", "c"]) != Thumbnails.scope(["a", "b-c"]))
        #expect(Thumbnails.scope(["a", "bc"]) != Thumbnails.scope(["ab", "c"]))
        #expect(Thumbnails.scope(["", "a"]) != Thumbnails.scope(["a", ""]))
    }

    @Test func equalPixelSizesWithDifferentDisplayScalesStaySeparate() async throws {
        let bytes = try png((255, 0, 0)), key = UUID().uuidString
        let first = try #require(await Thumbnails.load(bytes, key: key, points: 4, scale: 1))
        let second = try #require(await Thumbnails.load(bytes, key: key, points: 2, scale: 2))
        #expect(first !== second)
        #expect(first.size.width == 4)
        #expect(second.size.width == 2)
    }
}
