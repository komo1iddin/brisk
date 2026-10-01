import AppKit
import MapKit

/// Apple Maps pictures of a place, as WhatsApp shows a location: drawn by
/// MapKit, which asks Apple for the area around the coordinates. Kept in
/// memory only, per place, size and appearance: a picture of where someone
/// was is not written to disk outside the encrypted archive.
enum MapSnapshots {
    /// Street level: about this many metres from top to bottom.
    private static let span: CLLocationDistance = 450

    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    nonisolated static func key(latitude: Double, longitude: Double, size: CGSize, dark: Bool) -> String {
        String(format: "%.5f,%.5f@%.0fx%.0f-%@", latitude, longitude, size.width, size.height, dark ? "dark" : "light")
    }

    /// The picture `snapshot` made, if it is still kept.
    nonisolated static func cached(latitude: Double, longitude: Double, size: CGSize, dark: Bool) -> NSImage? {
        cache.object(forKey: key(latitude: latitude, longitude: longitude, size: size, dark: dark) as NSString)
    }

    /// The map around the place, centred on it, or nil offline or for
    /// coordinates that are not on Earth.
    @MainActor
    static func snapshot(latitude: Double, longitude: Double, size: CGSize, dark: Bool) async -> NSImage? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(center), size.width > 0, size.height > 0 else { return nil }
        let key = key(latitude: latitude, longitude: longitude, size: size, dark: dark) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center, latitudinalMeters: span, longitudinalMeters: span * size.width / size.height
        )
        options.size = size
        options.mapType = .standard
        options.pointOfInterestFilter = .excludingAll
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }
        let image = snapshot.image
        cache.setObject(image, forKey: key)
        return image
    }
}
