import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ZapFastCore

struct MediaEditTests {
    private func drawn() -> MediaEdit {
        var edit = MediaEdit()
        edit.crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        edit.strokes = [MediaStroke(brush: .pen, color: .white, points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.7, y: 0.9)])]
        edit.overlays = [MediaOverlay(content: .text("hi"), center: CGPoint(x: 0.25, y: 0.75), rotation: 0.3)]
        return edit
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test func aQuarterTurnTakesTheCropAndDrawingsRoundWithIt() {
        var edit = MediaEdit()
        // The left half becomes the bottom half.
        edit.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        edit.overlays = [MediaOverlay(content: .emoji("🙂"), center: CGPoint(x: 0, y: 0))]
        edit.rotateLeft()
        #expect(edit.turns == 1)
        #expect(close(edit.crop, CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))
        // The top left corner goes to the bottom left.
        #expect(edit.overlays[0].center == CGPoint(x: 0, y: 1))
        #expect(abs(edit.overlays[0].rotation + .pi / 2) < 1e-9)
    }

    @Test func fourTurnsOrTwoMirrorsChangeNothing() {
        let original = drawn()
        var edit = original
        for _ in 0..<4 { edit.rotateLeft() }
        #expect(edit.turns == 0)
        #expect(close(edit.crop, original.crop))
        for (a, b) in zip(edit.strokes[0].points, original.strokes[0].points) {
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9)
        }

        edit = original
        edit.mirror()
        #expect(edit.mirrored)
        #expect(close(edit.crop, CGRect(x: 0.4, y: 0.2, width: 0.5, height: 0.6)))
        #expect(edit.overlays[0].center.x == 0.75)
        edit.mirror()
        #expect(!edit.mirrored && close(edit.crop, original.crop))
        #expect(abs(edit.overlays[0].center.x - original.overlays[0].center.x) < 1e-9)
    }

    @Test func turningAMirroredCanvasStillTurnsItLeftAsItLooks() {
        var edit = MediaEdit()
        edit.mirror()
        edit.rotateLeft()
        // Under a mirror a turn to the left is three turns to the left.
        #expect(edit.turns == 3)
    }

    @Test func straighteningReadsClockwiseOnScreenEitherWayRound() {
        var edit = MediaEdit()
        edit.visibleStraighten = 10
        #expect(edit.straighten == -10)
        edit.mirror()
        #expect(edit.visibleStraighten == -10)
        edit.visibleStraighten = 90
        #expect(edit.visibleStraighten == MediaEdit.maxStraighten, "held within the dial")
    }

    @Test func resettingBringsTheDrawingsBackWithThePicture() {
        let original = drawn()
        var edit = original
        edit.rotateLeft()
        edit.mirror()
        edit.straighten = 12
        edit.resetGeometry()
        #expect(!edit.hasGeometry)
        #expect(abs(edit.overlays[0].center.x - original.overlays[0].center.x) < 1e-9)
        #expect(abs(edit.overlays[0].center.y - original.overlays[0].center.y) < 1e-9)
        #expect(!edit.strokes.isEmpty)
    }

    @Test func straighteningEnlargesThePictureJustEnoughToCover() {
        #expect(MediaEdit.coverScale(canvas: CGSize(width: 100, height: 100), straighten: 0) == 1)
        let square = MediaEdit.coverScale(canvas: CGSize(width: 100, height: 100), straighten: 45)
        #expect(abs(square - 2.0.squareRoot()) < 1e-9)
        let wide = MediaEdit.coverScale(canvas: CGSize(width: 200, height: 100), straighten: -10)
        #expect(wide > 1 && wide < 2)
    }

    @Test func anAspectCropIsAsLargeAsFitsAroundTheCurrentOne() {
        let canvas = CGSize(width: 2000, height: 1000)
        let square = MediaEdit.crop(aspect: 1, canvas: canvas, around: MediaEdit.full)
        #expect(close(square, CGRect(x: 0.25, y: 0, width: 0.5, height: 1)))
        let wide = MediaEdit.crop(aspect: 4, canvas: canvas, around: MediaEdit.full)
        #expect(close(wide, CGRect(x: 0, y: 0.25, width: 1, height: 0.5)))
        // Centred on a crop near the edge, it stays inside.
        let edge = MediaEdit.crop(aspect: 1, canvas: canvas, around: CGRect(x: 0.9, y: 0, width: 0.1, height: 1))
        #expect(close(edge, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
    }

    @Test func aStrokeWidthIsAShareOfTheLongerSide() {
        let stroke = MediaStroke(brush: .marker, color: .black, points: [CGPoint(x: 0.5, y: 0.5)])
        #expect(stroke.lineWidth(in: CGSize(width: 1000, height: 500)) == CGFloat(MediaStroke.Brush.marker.width) * 1000)
        #expect(!stroke.path(in: CGSize(width: 100, height: 100)).isEmpty, "a single click leaves a dot")
    }

    @Test func theColourStripRunsFromWhiteToBlackThenThroughTheHues() {
        #expect(MediaColor.strip(0) == .white)
        let black = MediaColor.strip(0.18)
        #expect(black.red < 0.01 && black.green < 0.01 && black.blue < 0.01)
        let red = MediaColor.strip(0.181)
        #expect(red.red == 1 && red.blue == 0)
        #expect(MediaColor.white.isLight && !MediaColor.black.isLight)
    }

    @Test func nothingDoneLeavesTheFileAsItIs() {
        var edit = MediaEdit()
        #expect(edit.isEmpty && !edit.changesPicture)
        edit.muted = true
        #expect(!edit.isEmpty && !edit.changesPicture)
    }
}

struct MediaExportTests {
    /// Red on the left half, blue on the right.
    private func picture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    /// The colour at a point counted from the top left.
    private func pixel(_ data: Data, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func size(_ data: Data) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    @Test func aTurnToTheLeftPutsTheRightSideOnTop() async throws {
        var edit = MediaEdit()
        edit.rotateLeft()
        let plan = MediaExport.planPhoto(try picture(width: 200, height: 100), edit: edit, quality: .hd)
        let data = try await MediaExport.renderPhoto(plan, edit: edit, overlays: [], quality: .hd)
        #expect(try size(data) == CGSize(width: 100, height: 200))
        let top = try pixel(data, x: 50, y: 10), bottom = try pixel(data, x: 50, y: 190)
        #expect(top.blue > 200 && top.red < 60)
        #expect(bottom.red > 200 && bottom.blue < 60)
    }

    @Test func mirroringSwapsTheSides() async throws {
        var edit = MediaEdit()
        edit.mirror()
        let plan = MediaExport.planPhoto(try picture(width: 200, height: 100), edit: edit, quality: .hd)
        let data = try await MediaExport.renderPhoto(plan, edit: edit, overlays: [], quality: .hd)
        #expect(try pixel(data, x: 10, y: 50).blue > 200)
    }

    @Test func theCropIsWhatIsSaved() async throws {
        var edit = MediaEdit()
        edit.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let plan = MediaExport.planPhoto(try picture(width: 200, height: 100), edit: edit, quality: .hd)
        let data = try await MediaExport.renderPhoto(plan, edit: edit, overlays: [], quality: .hd)
        #expect(try size(data) == CGSize(width: 100, height: 100))
        #expect(try pixel(data, x: 5, y: 50).blue > 200)
    }

    @Test func standardQualityKeepsTheLongerSideTo1600() async throws {
        let edit = MediaEdit()
        let big = try picture(width: 3200, height: 1600)
        let standard = MediaExport.planPhoto(big, edit: edit, quality: .standard)
        #expect(standard.output == CGSize(width: 1600, height: 800))
        let hd = MediaExport.planPhoto(big, edit: edit, quality: .hd)
        #expect(hd.output == CGSize(width: 3200, height: 1600), "never beyond the photo's own pixels")
    }

    @Test func aStrokeIsDrawnIntoThePicture() async throws {
        var edit = MediaEdit()
        edit.strokes = [MediaStroke(
            brush: .marker, color: MediaColor(red: 0, green: 1, blue: 0), width: 0.2,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)]
        )]
        let plan = MediaExport.planPhoto(try picture(width: 200, height: 100), edit: edit, quality: .hd)
        let data = try await MediaExport.renderPhoto(plan, edit: edit, overlays: [], quality: .hd)
        #expect(try pixel(data, x: 100, y: 50).green > 200)
        #expect(try pixel(data, x: 100, y: 5).green < 60, "only where it went")
    }

    @Test func pixelatingKeepsTheSize() throws {
        let image = try picture(width: 96, height: 48)
        let pixelated = try #require(MediaExport.pixelate(image))
        #expect(pixelated.width == 96 && pixelated.height == 48)
    }

    @Test func preparedFilesOlderThanADayAreSweptAway() async throws {
        let caches = FileManager.default.temporaryDirectory.appending(path: "zapfast-outgoing-\(UUID().uuidString)")
        let directory = MediaExport.outgoingDirectory(in: caches)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appending(path: "old.jpg"), fresh = directory.appending(path: "fresh.jpg")
        try Data([1]).write(to: old)
        try Data([1]).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        await MediaExport.sweepOutgoing(in: caches)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}
