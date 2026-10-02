import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

struct MediaQueueTests {
    private func items(_ count: Int, size: UInt64 = 10) -> [MediaQueue.Item] {
        (1...count).map { .init(message: "m\($0)", size: size) }
    }

    private func queue(_ count: Int, size: UInt64 = 10) -> MediaQueue {
        MediaQueue(items: items(count, size: size), limit: 100)
    }

    @Test func fewAreOnTheirWayAtOnceAndInOrder() {
        var queue = queue(7)
        let taken1 = queue.take()
        #expect(taken1.map(\.message) == ["m1", "m2", "m3"])
        let taken2 = queue.take()
        #expect(taken2.isEmpty, "the width is full")
        queue.finish("m2", failure: nil)
        let taken3 = queue.take()
        #expect(taken3.map(\.message) == ["m4"])
    }

    @Test func aFileOverTheLimitIsLeftOutFromTheStart() {
        let queue = MediaQueue(items: items(2, size: 10) + [.init(message: "big", size: 101)], limit: 100)
        #expect(queue.total == 2)
        #expect(queue.skippedLarge == 1)
    }

    @Test func fileThatIsGoneAreCountedAndTheQueueGoesOn() {
        var queue = queue(4)
        _ = queue.take()
        queue.finish("m1", failure: .gone)
        queue.finish("m2", failure: nil)
        #expect(queue.gone == 1 && queue.done == 1)
        let taken4 = queue.take()
        #expect(taken4.map(\.message) == ["m4"])
        #expect(queue.pause == nil)
    }

    @Test func aPhoneThatStaysSilentPausesTheQueue() {
        var queue = queue(8)
        _ = queue.take()
        for message in ["m1", "m2", "m3"] { queue.finish(message, failure: .phoneSilent) }
        #expect(queue.pause == .phoneSilent)
        let taken5 = queue.take()
        #expect(taken5.isEmpty)
        #expect(queue.held.count == 3)
        #expect(queue.isOver)

        queue.resume()
        #expect(queue.pause == nil)
        let taken6 = queue.take()
        #expect(taken6.map(\.message) == ["m1", "m2", "m3"], "the unanswered go first")
    }

    @Test func anAnswerFromThePhoneBreaksTheSilence() {
        var queue = queue(8)
        _ = queue.take()
        queue.finish("m1", failure: .phoneSilent)
        queue.finish("m2", failure: .phoneSilent)
        queue.finish("m3", failure: .gone)
        _ = queue.take()
        queue.finish("m4", failure: .phoneSilent)
        #expect(queue.pause == nil)
    }

    @Test func noConnectionPausesAtOnce() {
        var queue = queue(5)
        _ = queue.take()
        queue.finish("m1", failure: .offline)
        #expect(queue.pause == .offline)
        #expect(queue.held.map(\.message) == ["m1"])
    }

    @Test func aFileThatFailedForNoClearReasonIsTriedOnceMoreAtTheEnd() {
        var queue = queue(1)
        let taken7 = queue.take()
        #expect(taken7.map(\.message) == ["m1"])
        queue.finish("m1", failure: .timedOut)
        #expect(!queue.isOver)
        let taken8 = queue.take()
        #expect(taken8.map(\.message) == ["m1"])
        queue.finish("m1", failure: .other("reset"))
        #expect(queue.isOver)
        #expect(queue.failed == 1)
    }

    @Test func stoppingStartsNothingMoreButLetsTheRunningOnesLand() {
        var queue = queue(6)
        _ = queue.take()
        queue.stop()
        #expect(!queue.isOver)
        queue.finish("m1", failure: nil)
        queue.finish("m2", failure: nil)
        queue.finish("m3", failure: nil)
        #expect(queue.isOver)
        #expect(queue.done == 3)
        let taken9 = queue.take()
        #expect(taken9.isEmpty)
    }

    @Test func aFinishNobodyAskedForChangesNothing() {
        var queue = queue(2)
        _ = queue.take()
        queue.finish("elsewhere", failure: .gone)
        #expect(queue.gone == 0)
    }
}

struct HistoryRunTests {
    @Test func theRunGoesOnWhileMessagesComeAndEndsWhenThePhoneHasNoMore() {
        var run = HistoryRun()
        run.arrived(50)
        let again1 = run.answered(more: true)
        #expect(again1)
        run.arrived(30)
        let again2 = run.answered(more: false)
        #expect(!again2)
        #expect(run.state == .exhausted)
        #expect(run.loaded == 80)
    }

    @Test func twoAnswersInARowThatBringNothingMeanTheyAreSilent() {
        var run = HistoryRun()
        let again3 = run.answered(more: true)
        #expect(again3)
        let again4 = run.answered(more: true)
        #expect(!again4)
        #expect(run.state == .silent)
    }

    @Test func oneEmptyAnswerBetweenGoodOnesIsForgiven() {
        var run = HistoryRun()
        run.arrived(50)
        let again5 = run.answered(more: true)
        #expect(again5)
        let again6 = run.answered(more: true)
        #expect(again6)
        run.arrived(50)
        let again7 = run.answered(more: true)
        #expect(again7)
        let again8 = run.answered(more: true)
        #expect(again8)
        #expect(run.state == .asking)
    }

    @Test func stoppingEndsItAndALateAnswerChangesNothing() {
        var run = HistoryRun()
        run.end(.stopped)
        run.arrived(50)
        let again9 = run.answered(more: true)
        #expect(!again9)
        #expect(run.state == .stopped)
        #expect(run.loaded == 0)
    }
}

@MainActor
struct PhoneFetchTests {
    private final class Reader: ChatReaderProtocol, @unchecked Sendable {
        let census: ChatCensus
        init(_ census: ChatCensus) { self.census = census }
        func census(chat: String) throws -> ChatCensus { census }
        func page(chat: String, before: PageKey?, limit: UInt32) throws -> [MessageRecord] { [] }
    }

    private final class Phone {
        var downloads: [String] = []
        var asks = 0
        var connected = true
        var notices: [String] = []
        var census: ChatCensus
        let gone = GoneMedia(defaults: UserDefaults(suiteName: "PhoneFetchTests-\(UUID().uuidString)")!)

        init(_ media: [ChatMedia], messages: UInt64 = 100) {
            census = ChatCensus(messages: messages, oldest: 1_700_000_000, media: media)
        }
    }

    private func item(_ id: String, _ kind: ChatMediaKind, here: Bool = false, size: UInt64 = 1000) -> ChatMedia {
        ChatMedia(message: id, timestamp: 1, kind: kind, size: size, here: here)
    }

    private func fetch(_ phone: Phone) -> PhoneFetch {
        PhoneFetch(chat: "c@s.whatsapp.net", hooks: .init(
            openReader: { Reader(phone.census) },
            download: { phone.downloads.append($0) },
            askOlder: { phone.asks += 1 },
            isConnected: { phone.connected },
            finished: { phone.notices.append($0) },
            gone: phone.gone
        ))
    }

    private func ready(_ fetch: PhoneFetch) async {
        for _ in 0..<200 where fetch.phase == .counting { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theCountSaysWhatIsMissingByKind() async {
        let phone = Phone([
            item("p1", .photo), item("p2", .photo, here: true), item("v1", .voice), item("a1", .audio),
            item("d1", .document, size: 200 * 1024 * 1024), item("d2", .document),
        ])
        let fetch = fetch(phone)
        await ready(fetch)
        #expect(fetch.phase == .ready)
        #expect(fetch.messages == 100)
        #expect(fetch.counts[.photos] == .init(total: 2, missing: 1, missingBytes: 1000, tooLarge: 0))
        #expect(fetch.counts[.audio]?.missing == 2)
        #expect(fetch.counts[.files] == .init(total: 2, missing: 1, missingBytes: 1000, tooLarge: 1))
        #expect(fetch.wanted == 4)
        fetch.selected = [.audio]
        #expect(fetch.wanted == 2)
    }

    @Test func downloadingTakesTheChosenKindsNewestFirstAFewAtATime() async {
        let phone = Phone([
            item("n1", .photo), item("n2", .photo), item("n3", .voice), item("n4", .voice),
            item("n5", .document), item("here", .photo, here: true),
        ])
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.selected = [.photos, .audio]
        fetch.startFiles()
        #expect(phone.downloads == ["n1", "n2", "n3"])
        fetch.fileFinished(message: "n1", error: nil)
        #expect(phone.downloads == ["n1", "n2", "n3", "n4"])
        fetch.fileFinished(message: "n2", error: nil)
        fetch.fileFinished(message: "n3", error: "No longer available on WhatsApp's servers")
        #expect(phone.notices.isEmpty, "one is still on its way")
        fetch.fileFinished(message: "n4", error: nil)
        #expect(phone.notices == ["Downloaded 3 of 4 files. 1 are no longer available."])
        #expect(!fetch.isRunning)
    }

    @Test func aSilentPhoneStopsTheQueueUntilTheyContinue() async {
        let phone = Phone((1...9).map { item("f\($0)", .document) })
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.startFiles()
        let silent = "Your phone did not answer. Open WhatsApp on it and try again"
        for id in ["f1", "f2", "f3"] { fetch.fileFinished(message: id, error: silent) }
        #expect(fetch.queue?.pause == .phoneSilent)
        // Two more were started while the first answers came in: they land too.
        #expect(phone.downloads == ["f1", "f2", "f3", "f4", "f5"])
        #expect(fetch.isRunning)
        for id in ["f4", "f5"] { fetch.fileFinished(message: id, error: silent) }
        #expect(!fetch.isRunning)
        #expect(phone.notices.isEmpty, "waiting for the person, not finished")
        #expect(phone.downloads.count == 5, "nothing more is asked of a silent phone")

        fetch.resumeFiles()
        #expect(phone.downloads.suffix(3) == ["f1", "f2", "f3"])
        #expect(fetch.isRunning)
    }

    @Test func noConnectionWaitsAndTheLinkComingBackGoesOn() async {
        let phone = Phone((1...4).map { item("f\($0)", .photo) })
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.startFiles()
        phone.connected = false
        fetch.fileFinished(message: "f1", error: "Not connected to WhatsApp")
        #expect(fetch.queue?.pause == .offline)
        let before = phone.downloads.count
        fetch.linkConnected()
        #expect(phone.downloads.count == before, "still not connected")
        phone.connected = true
        fetch.linkConnected()
        #expect(fetch.queue?.pause == nil)
        #expect(phone.downloads.count > before)
    }

    @Test func historyAsksAgainWhileMessagesComeAndStopsWhenThePhoneHasNone() async {
        let phone = Phone([])
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.startHistory()
        #expect(phone.asks == 1)
        fetch.olderArrived(count: 50)
        fetch.olderAnswered(more: true)
        #expect(phone.asks == 2)
        fetch.olderArrived(count: 12)
        fetch.olderAnswered(more: false)
        #expect(phone.asks == 2)
        #expect(fetch.run?.state == .exhausted)
        #expect(fetch.run?.loaded == 62)
        #expect(!fetch.isRunning)
    }

    @Test func historyWithoutAConnectionDoesNotAsk() async {
        let phone = Phone([])
        phone.connected = false
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.startHistory()
        #expect(phone.asks == 0)
        #expect(fetch.run?.state == .offline)
    }

    @Test func stoppingHistoryIgnoresTheAnswerThatIsStillOnItsWay() async {
        let phone = Phone([])
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.startHistory()
        fetch.stopHistory()
        fetch.olderArrived(count: 50)
        fetch.olderAnswered(more: true)
        #expect(phone.asks == 1)
        #expect(fetch.run?.state == .stopped)
    }
}

@MainActor
extension PhoneFetchTests {
    @Test func aFileThePhoneLostIsRememberedAndNotAskedForAgain() async {
        let phone = Phone([item("a", .document), item("b", .document), item("c", .document)])
        let fetch = fetch(phone)
        await ready(fetch)
        fetch.startFiles()
        fetch.fileFinished(message: "a", error: "No longer available on WhatsApp's servers")
        fetch.fileFinished(message: "b", error: nil)
        fetch.fileFinished(message: "c", error: nil)
        #expect(phone.gone.contains(chat: "c@s.whatsapp.net", message: "a"))
        #expect(!phone.gone.contains(chat: "c@s.whatsapp.net", message: "b"))

        // A later look at the chat counts it apart and does not queue it.
        let again = self.fetch(phone)
        await ready(again)
        #expect(again.counts[.files]?.unavailable == 1)
        #expect(again.counts[.files]?.missing == 2, "the census still says b and c are not on this Mac")
        again.startFiles()
        #expect(!phone.downloads.suffix(3).contains("a"))
    }
}

@MainActor
struct GoneMediaTests {
    private func store() -> (GoneMedia, UserDefaults) {
        let defaults = UserDefaults(suiteName: "GoneMediaTests-\(UUID().uuidString)")!
        return (GoneMedia(defaults: defaults), defaults)
    }

    @Test func itKeepsHashesAcrossLaunchesNotIds() {
        let (gone, defaults) = store()
        gone.insert(chat: "a@s.whatsapp.net", message: "3EB0AAAA")
        gone.save()
        #expect(gone.contains(chat: "a@s.whatsapp.net", message: "3EB0AAAA"))
        #expect(!gone.contains(chat: "b@s.whatsapp.net", message: "3EB0AAAA"))
        let saved = defaults.stringArray(forKey: "goneMedia") ?? []
        #expect(saved.count == 1 && !saved[0].contains("3EB0"))
        #expect(GoneMedia(defaults: defaults).contains(chat: "a@s.whatsapp.net", message: "3EB0AAAA"))
    }

    @Test func itForgetsTheOldestPastItsLimit() {
        let (gone, _) = store()
        for index in 0..<(GoneMedia.limit + 5) { gone.insert(chat: "c", message: "m\(index)") }
        #expect(!gone.contains(chat: "c", message: "m0"))
        #expect(gone.contains(chat: "c", message: "m\(GoneMedia.limit + 4)"))
    }

    @Test func clearingForgetsAll() {
        let (gone, defaults) = store()
        gone.insert(chat: "c", message: "m")
        gone.clear()
        #expect(!gone.contains(chat: "c", message: "m"))
        #expect(defaults.stringArray(forKey: "goneMedia") == nil)
    }
}
