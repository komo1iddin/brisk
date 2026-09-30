import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct ThemeTests {
    private func store(_ defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!) -> (ThemeStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zapfast-themes-\(UUID().uuidString)")
        return (ThemeStore(defaults: defaults, wallpapersFolder: folder), folder)
    }

    @Test func chatsFollowTheDefaultUntilTheyHaveTheirOwn() {
        let (themes, _) = store()
        #expect(themes.appearance(for: nil) == ThemePresets.system, "the Mac's own look to start with")
        #expect(ThemePresets.system.bubble == nil, "the system accent colour")
        let iris = ThemePresets.all.first { $0.id == "iris" }!.appearance
        themes.set(iris, for: "a@s.whatsapp.net")
        #expect(themes.appearance(for: "a@s.whatsapp.net") == iris)
        #expect(themes.appearance(for: "b@s.whatsapp.net") == ThemePresets.system)

        let plain = ThemePresets.all.first { $0.id == "plain-blue" }!.appearance
        themes.set(plain, for: nil)
        #expect(themes.appearance(for: "b@s.whatsapp.net") == plain)
        #expect(themes.appearance(for: "a@s.whatsapp.net") == iris)

        themes.useDefault(for: "a@s.whatsapp.net")
        #expect(themes.appearance(for: "a@s.whatsapp.net") == plain)
        #expect(!themes.hasOwnAppearance("a@s.whatsapp.net"))
    }

    @Test func looksSurviveARestart() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let custom = ChatAppearance(bubble: ThemeColor("#123456"), wallpaper: .color(ThemeColor(light: "#f5f1eb", dark: "#161717"), doodles: false))
        store(defaults).0.set(custom, for: "a@s.whatsapp.net")
        store(defaults).0.set(ThemePresets.all[3].appearance, for: nil)

        let (reopened, _) = store(defaults)
        #expect(reopened.appearance(for: "a@s.whatsapp.net") == custom)
        #expect(reopened.appearance(for: nil) == ThemePresets.all[3].appearance)
    }

    @Test func photosAreScaledCopiesKeptOnlyWhileUsed() async throws {
        let (themes, folder) = store()
        let source = FileManager.default.temporaryDirectory.appending(path: "zapfast-wall-\(UUID().uuidString).png")
        let context = try #require(CGContext(
            data: nil, width: 3000, height: 100, bitsPerComponent: 8, bytesPerRow: 12000,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 100))
        let picture = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        #expect(CGImageDestinationFinalize(destination))

        let name = try #require(await themes.importPhoto(source))
        let copy = try #require(CGImageSourceCreateWithURL(themes.photoURL(name) as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(copy, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == ThemeStore.maximumSide)

        themes.set(ChatAppearance(bubble: ThemePresets.whatsAppGreen, wallpaper: .photo(name, dim: 0.3)), for: "a@s.whatsapp.net")
        #expect(FileManager.default.fileExists(atPath: themes.photoURL(name).path(percentEncoded: false)))
        themes.useDefault(for: "a@s.whatsapp.net")
        #expect(!FileManager.default.fileExists(atPath: themes.photoURL(name).path(percentEncoded: false)))
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func wallpaperColoursComeFromUpstream() {
        let light = WallpaperColors.choices(dark: false)
        #expect(light.first?.hex == "#f5f1eb")
        #expect(WallpaperColors.choices(dark: true).allSatisfy { $0.hex.count == 7 })
        #expect(doodleInk(backgroundHex: "#efeae2").count == 9)
    }

    @Test func everyPresetNamesARealGradient() {
        for preset in ThemePresets.all {
            if case .gradient(let id) = preset.appearance.wallpaper {
                #expect(ThemePresets.gradient(id) != nil, "\(preset.id)")
            }
        }
        #expect(ThemePresets.gradients.allSatisfy { $0.light.count == 4 && $0.dark.count == 4 })
    }
}
