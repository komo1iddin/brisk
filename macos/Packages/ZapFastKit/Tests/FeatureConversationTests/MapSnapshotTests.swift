import AppKit
import Testing
@testable import FeatureConversation

@MainActor
struct MapSnapshotTests {
    @Test func aPlaceNotOnEarthAsksNobody() async {
        // Nothing is kept or asked for: an invalid place returns at once.
        let image = await MapSnapshots.snapshot(latitude: 200, longitude: 69.28, size: CGSize(width: 300, height: 170), dark: false)
        #expect(image == nil)
        #expect(MapSnapshots.cached(latitude: 200, longitude: 69.28, size: CGSize(width: 300, height: 170), dark: false) == nil)
    }

    @Test func eachAppearanceAndSizeIsItsOwnPicture() {
        let size = CGSize(width: 300, height: 170)
        let light = MapSnapshots.key(latitude: 41.3111, longitude: 69.2797, size: size, dark: false)
        #expect(light != MapSnapshots.key(latitude: 41.3111, longitude: 69.2797, size: size, dark: true))
        #expect(light != MapSnapshots.key(latitude: 41.3111, longitude: 69.2797, size: CGSize(width: 200, height: 170), dark: false))
        #expect(light != MapSnapshots.key(latitude: 41.3112, longitude: 69.2797, size: size, dark: false))
    }
}
