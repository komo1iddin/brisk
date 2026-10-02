import Testing
@testable import ZapFastCore

struct DownloadFailureTests {
    @Test func theBackendsWordsAreToldApart() {
        #expect(DownloadFailure("No longer available on WhatsApp's servers") == .gone)
        #expect(DownloadFailure("Your phone did not answer. Open WhatsApp on it and try again") == .phoneSilent)
        #expect(DownloadFailure("Your phone could not upload it again") == .phoneRefused)
        #expect(DownloadFailure("Not connected to WhatsApp") == .offline)
        #expect(DownloadFailure("This attachment is larger than the 64 MiB download limit") == .tooLarge)
        #expect(DownloadFailure("Download timed out") == .timedOut)
    }

    @Test func anExpiredLinkWithNoKeyToAskWithIsGone() {
        #expect(DownloadFailure("Download failed with status: 403") == .gone)
        #expect(DownloadFailure("Download failed with status: 410") == .gone)
    }

    @Test func anythingElseKeepsItsWords() {
        #expect(DownloadFailure("connection reset") == .other("connection reset"))
        #expect(DownloadFailure("connection reset").explanation == "connection reset")
    }

    @Test func aSilentPhoneIsNotFinalButAGoneFileIs() {
        #expect(!DownloadFailure.phoneSilent.isFinal)
        #expect(DownloadFailure.phoneSilent.needsPhone)
        #expect(DownloadFailure.gone.isFinal)
        #expect(!DownloadFailure.gone.needsPhone)
    }

    @Test func aStateSaysWhyItFailed() {
        #expect(DownloadState.failed("Your phone did not answer. Open WhatsApp on it and try again").failure == .phoneSilent)
        #expect(DownloadState.downloading.failure == nil)
    }
}
