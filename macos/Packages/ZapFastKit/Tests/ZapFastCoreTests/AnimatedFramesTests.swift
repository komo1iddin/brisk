import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ZapFastDesign

@MainActor
struct AnimatedFramesTests {
    private func gif(frames: Int, size: Int = 16) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "animated-fixture-\(UUID()).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, frames, nil))
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<frames {
            context.setFillColor(CGColor(red: CGFloat(index % 255) / 255, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    @Test func manyFramesFitTheDecodeBudgetBeforeEnteringTheCache() async throws {
        let file = try gif(frames: 150, size: 256)
        defer { try? FileManager.default.removeItem(at: file) }
        let frames = try #require(await AnimatedFrames.load(file, points: 320))
        #expect(frames.frames.count == 150)
        #expect(frames.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } <= AnimatedFrames.byteLimit)
        #expect(frames.contentsAnimation().duration > 14)
    }

    @Test func excessFramesKeepTheStillPreview() async throws {
        let file = try gif(frames: 151)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await AnimatedFrames.load(file, points: 160) == nil)
    }

    @Test func concurrentReadersShareTheSameFramesAndSourceRemovalCannotUseTheCache() async throws {
        let file = try gif(frames: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        let results = await withTaskGroup(of: AnimatedFrames?.self) { group in
            for _ in 0..<12 { group.addTask { await AnimatedFrames.load(file, points: 160) } }
            var results: [AnimatedFrames] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0 === results.first })
        try FileManager.default.removeItem(at: file)
        #expect(await AnimatedFrames.load(file, points: 160) == nil)
    }

    @Test func invalidSizesDoNotAllocateFrames() async throws {
        let file = try gif(frames: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await AnimatedFrames.load(file, points: .infinity) == nil)
        #expect(await AnimatedFrames.load(file, points: 100, scale: .nan) == nil)
    }

    private actor Probe {
        var running = 0
        var maximum = 0
        func decode() async -> AnimatedFrames? {
            running += 1
            maximum = max(maximum, running)
            try? await Task.sleep(for: .milliseconds(15))
            running -= 1
            return nil
        }
    }

    @Test func burstsHaveAtMostTwoDecoders() async {
        let probe = Probe()
        let loader = AnimatedFrameLoader { _, _ in await probe.decode() }
        await withTaskGroup(of: AnimatedFrames?.self) { group in
            for index in 0..<30 {
                group.addTask { await loader.load(URL(filePath: "/synthetic/\(index)"), pixels: 1, key: "\(index)") }
            }
            for await _ in group {}
        }
        #expect(await probe.maximum == 2)
    }
}
