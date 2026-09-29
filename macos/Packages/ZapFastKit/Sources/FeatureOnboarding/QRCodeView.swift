import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code drawn crisp at any size: generated once per payload with
/// CoreImage, scaled without interpolation. The payload is a pairing
/// secret; it is never logged or copied.
struct QRCodeView: View {
    let payload: String

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .padding(14)
        // A QR code needs a light quiet zone in either appearance.
        .background(.white, in: .rect(cornerRadius: 12))
        .task(id: payload) {
            image = Self.render(payload)
        }
        .accessibilityLabel("QR code to link this Mac")
    }

    private static func render(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
