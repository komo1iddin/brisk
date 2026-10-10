import Foundation
import QuartzCore
import Testing
import ZapFastCore
import ZapFastDesign

/// A menu grows out of the point it was opened from.
@MainActor
@Suite struct MenuOpeningTests {
    private let frame = NSRect(x: 100, y: 200, width: 160, height: 300)

    @Test func aMenuBelowThePointerGrowsFromItsTopCorner() {
        let pivot = MenuOpening.pivot(
            pointer: NSPoint(x: 100, y: 500), in: frame, size: frame.size, flipped: false, anchor: .zero
        )
        #expect(pivot == CGPoint(x: 0, y: 300))
    }

    /// A menu moved to fit the screen, or hung below a toolbar button,
    /// grows from its own edge nearest the pointer.
    @Test func thePivotStaysInsideTheMenu() {
        let below = MenuOpening.pivot(
            pointer: NSPoint(x: 180, y: 540), in: frame, size: frame.size, flipped: false, anchor: .zero
        )
        #expect(below == CGPoint(x: 80, y: 300))
        let away = MenuOpening.pivot(
            pointer: NSPoint(x: 900, y: 40), in: frame, size: frame.size, flipped: false, anchor: .zero
        )
        #expect(away == CGPoint(x: 160, y: 0))
    }

    @Test func aFlippedOrCentredLayerTurnsAroundTheSamePoint() {
        let flipped = MenuOpening.pivot(
            pointer: NSPoint(x: 100, y: 500), in: frame, size: frame.size, flipped: true, anchor: .zero
        )
        #expect(flipped == CGPoint(x: 0, y: 0))
        let centred = MenuOpening.pivot(
            pointer: NSPoint(x: 100, y: 500), in: frame, size: frame.size, flipped: false,
            anchor: CGPoint(x: 0.5, y: 0.5)
        )
        #expect(centred == CGPoint(x: -80, y: 150))
    }

    @Test func scalingLeavesThePivotWhereItIs() {
        let scaling = CATransform3DGetAffineTransform(MenuOpening.scaling(0.5, about: CGPoint(x: 0, y: 300)))
        let stays = CGPoint(x: 0, y: 300).applying(scaling)
        #expect(abs(stays.x) < 0.001 && abs(stays.y - 300) < 0.001)
        let comes = CGPoint(x: 160, y: 0).applying(scaling)
        #expect(abs(comes.x - 80) < 0.001 && abs(comes.y - 150) < 0.001)
    }

    @Test func menusGrowUntilSettingsTurnItOff() {
        let name = "MenuOpeningTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.menuAnimation)
        preferences.menuAnimation = false
        #expect(!Preferences(defaults: defaults).menuAnimation, "kept for the next launch")
    }
}
