/// A location inside a bubble, live or not.

import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A place as WhatsApp shows it: an Apple Maps picture of the street around
/// it with a pin on the spot (the sender's own preview until it is drawn,
/// or when it cannot be), then the place's name and address, or for a live
/// location when it last moved, how fast and how precisely. The map runs
/// almost to the bubble's edge, as a photo does. A click opens it in Maps.
struct LocationContent: View {
    let message: MessageRecord
    let latitude: Double
    let longitude: Double
    let title: String
    let detail: String?
    let live: Bool
    let model: AppModel
    /// A live location's latest update, so its picture is reloaded.
    var version: Int64 = 0
    /// The text keeps the usual inset beside the map.
    var inset = true

    @State private var picture: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    /// As a landscape photo; the room is kept from the start, as the row
    /// is measured once.
    static let mapSize = CGSize(width: 300, height: 170)

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Metrics.xs) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: Self.mapSize.width, height: Self.mapSize.height)
                    .overlay {
                        if let picture {
                            Image(nsImage: picture)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: Self.mapSize.width, height: Self.mapSize.height)
                        }
                    }
                    .overlay { MapPin(color: live ? .blue : .red) }
                    .clipShape(.rect(cornerRadius: Metrics.bubbleRadius - Metrics.xs, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(2)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(width: Self.mapSize.width - (inset ? Metrics.s * 2 : 0), alignment: .leading)
                .insetForMedia(inset)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open in Maps")
        .task(id: "\(message.id)-\(version)-\(latitude),\(longitude)-\(colorScheme == .dark)") { await load() }
    }

    /// The map, or the sender's preview while it is drawn and when it
    /// cannot be (offline).
    private func load() async {
        let dark = colorScheme == .dark
        if let cached = MapSnapshots.cached(latitude: latitude, longitude: longitude, size: Self.mapSize, dark: dark) {
            picture = cached
            return
        }
        if let thumbnail = message.thumbnail {
            picture = await Thumbnails.load(thumbnail, key: "map-\(message.id)-\(version)", points: Self.mapSize.width)
        }
        if let map = await MapSnapshots.snapshot(latitude: latitude, longitude: longitude, size: Self.mapSize, dark: dark) {
            withAnimation(.easeOut(duration: 0.15)) { picture = map }
        }
    }

    /// "Updated 14:05 · 31 km/h · ±12 m", as upstream words a live location.
    static func liveDetail(updated: Int64, speed: Float?, accuracy: UInt32?) -> String? {
        var parts: [String] = []
        if updated > 0 {
            parts.append(String(localized: "Updated \(DateText.bubble(updated))"))
        }
        if let speed, speed >= 0.5 {
            let kmh = Measurement(value: Double(speed), unit: UnitSpeed.metersPerSecond).converted(to: .kilometersPerHour)
            parts.append(kmh.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))))
        }
        if let accuracy, accuracy > 0 {
            parts.append("±\(accuracy) m")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func open() {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
        if !live, title != String(localized: "Location") {
            components.queryItems?.append(URLQueryItem(name: "q", value: title))
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

/// The pin WhatsApp puts on a place: a round head on a short needle whose
/// point is the spot, the map's centre.
struct MapPin: View {
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(color.gradient)
                .frame(width: 16, height: 16)
                .overlay(alignment: .topLeading) {
                    Circle().fill(.white.opacity(0.55)).frame(width: 5, height: 5).offset(x: 3.5, y: 3.5)
                }
            Rectangle()
                .fill(Color(white: 0.4))
                .frame(width: 1.5, height: 15)
        }
        .shadow(color: .black.opacity(0.3), radius: 1.5, x: 1, y: 1)
        // The needle's point on the centre.
        .offset(y: -15.5)
    }
}
