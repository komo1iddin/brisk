import AppKit
import Testing
@testable import FeatureConversation

/// The voice button's glyphs morph into one another, so each must be made
/// of the same outlines, inside the disc.
@MainActor
struct PlayButtonTests {
    private let glyphs: [PlayButtonLayer.Glyph] = [.play, .pause, .download, .none]

    @Test func everyGlyphIsTwoFourPointOutlines() {
        for glyph in glyphs {
            let outlines = PlayButtonLayer.outlines(glyph)
            #expect(outlines.count == 2)
            #expect(outlines.allSatisfy { $0.count == 4 })
        }
    }

    @Test func pathsHaveTheSameElementsSoTheyMorph() {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        let counts = glyphs.map { glyph in
            var count = 0
            PlayButtonLayer.path(glyph, in: bounds).applyWithBlock { _ in count += 1 }
            return count
        }
        #expect(Set(counts).count == 1)
    }

    @Test func glyphsStayInsideTheDisc() {
        for glyph in glyphs {
            for point in PlayButtonLayer.outlines(glyph).joined() {
                #expect((point.x * point.x + point.y * point.y).squareRoot() < 12)
            }
        }
    }

    @Test func theDownloadArrowPointsDown() {
        // y runs down: the head's tip is below the shaft.
        let head = PlayButtonLayer.outlines(.download)[1]
        let shaft = PlayButtonLayer.outlines(.download)[0]
        #expect(head.map(\.y).max()! > shaft.map(\.y).max()!)
    }
}
