import AppKit
import Testing
@testable import FeatureConversation

@MainActor
struct LocationPreviewTests {
    @Test func aLocationWithoutASenderPreviewHasNoMapPicture() async {
        let image = await LocationPreview.load(nil, key: UUID().uuidString, points: 300)
        #expect(image == nil)
    }

    @Test func anUnreadableSenderPreviewHasNoNetworkFallback() async {
        let image = await LocationPreview.load(Data("not an image".utf8), key: UUID().uuidString, points: 300)
        #expect(image == nil)
    }

    @Test func aSenderPreviewDecodesFromLocalBytes() async throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let image = await LocationPreview.load(data, key: UUID().uuidString, points: 300)
        #expect(image != nil)
    }
}
