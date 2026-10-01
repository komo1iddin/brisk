import Testing
import ZapFastDesign

/// Message text beside a bubble: white where white reads, as messengers set it.
@Suite struct BubbleTextColorTests {
    @Test func midBlueTakesWhiteText() {
        #expect(HexColor.text(on: "#0a84ff") == "#ffffff")
        #expect(HexColor.text(on: "#6a5cf0") == "#ffffff")
    }

    @Test func darkBubblesTakeWhiteText() {
        #expect(HexColor.text(on: "#005c4b") == "#ffffff")
        #expect(HexColor.text(on: "#48484a") == "#ffffff")
    }

    @Test func lightBubblesTakeDarkText() {
        #expect(HexColor.text(on: "#d9fdd3") == "#111b21")
        #expect(HexColor.text(on: "#f2a33a") == "#111b21")
    }
}
