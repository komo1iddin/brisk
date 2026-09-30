import CoreGraphics
import Foundation
import Testing
import ZapFastDesign

/// Pictures are converted to the display's layout on the decoder's thread,
/// so Core Animation does not convert them on the main thread.
struct DisplayImageTests {
    @Test func convertsOffTheMainThreadToTheDisplaysLayout() async {
        let space = CGColorSpace(name: CGColorSpace.genericRGBLinear)!
        let context = CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let source = context.makeImage()!
        let prepared = await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.display-image").async {
                continuation.resume(returning: DisplayImage.prepare(source))
            }
        }
        #expect(prepared.colorSpace == DisplayImage.colorSpace)
        #expect(prepared.bitmapInfo.rawValue == CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        #expect(prepared.width == 8 && prepared.height == 4)
        // Already in shape: returned as it is.
        #expect(DisplayImage.prepare(prepared) === prepared)
    }
}
