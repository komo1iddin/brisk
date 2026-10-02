import Foundation
import Network
import Testing
@testable import ZapFastCore

@MainActor
struct LinkRecoveryTests {
    private let wifi = LinkRecovery.Network(reachable: true, interfaces: [.wifi])
    private let ethernet = LinkRecovery.Network(reachable: true, interfaces: [.wiredEthernet])
    private let offline = LinkRecovery.Network(reachable: false, interfaces: [])
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func theFirstSightingOfTheNetworkChangesNothing() {
        var recovery = LinkRecovery()
        #expect(recovery.observe(wifi, connected: false, at: start) == .wait)
    }

    @Test func aNetworkThatReturnsRedialsALinkThatIsDown() {
        var recovery = LinkRecovery()
        _ = recovery.observe(wifi, connected: true, at: start)
        #expect(recovery.observe(offline, connected: false, at: start) == .wait)
        #expect(recovery.observe(wifi, connected: false, at: start + 60) == .reconnect)
    }

    @Test func aLinkThatStayedUpIsLeftAlone() {
        var recovery = LinkRecovery()
        _ = recovery.observe(wifi, connected: true, at: start)
        #expect(recovery.observe(offline, connected: true, at: start) == .wait)
        #expect(recovery.observe(wifi, connected: true, at: start + 5) == .wait)
        #expect(recovery.nextTry == nil)
    }

    @Test func movingToAnotherNetworkRedialsALinkThatIsDown() {
        var recovery = LinkRecovery()
        _ = recovery.observe(wifi, connected: false, at: start)
        #expect(recovery.observe(ethernet, connected: false, at: start + 5) == .reconnect)
    }

    @Test func anUnchangedNetworkDoesNotRedialAgain() {
        var recovery = LinkRecovery()
        _ = recovery.observe(wifi, connected: false, at: start)
        #expect(recovery.observe(wifi, connected: false, at: start + 5) == .wait)
    }

    @Test func goingOfflineCancelsTheFollowUps() {
        var recovery = LinkRecovery()
        _ = recovery.observe(offline, connected: false, at: start)
        _ = recovery.observe(wifi, connected: false, at: start)
        #expect(recovery.nextTry != nil)
        #expect(recovery.observe(offline, connected: false, at: start + 3) == .wait)
        #expect(recovery.nextTry == nil)
        #expect(recovery.tick(connected: false, at: start + 600) == .wait)
    }

    @Test func followUpsComeAtGrowingGapsAndStop() {
        var recovery = LinkRecovery()
        _ = recovery.observe(offline, connected: false, at: start)
        #expect(recovery.observe(wifi, connected: false, at: start) == .reconnect)
        #expect(recovery.tick(connected: false, at: start + 14) == .wait)
        #expect(recovery.tick(connected: false, at: start + 15) == .reconnect)
        #expect(recovery.tick(connected: false, at: start + 44) == .wait)
        #expect(recovery.tick(connected: false, at: start + 45) == .reconnect)
        #expect(recovery.tick(connected: false, at: start + 104) == .wait)
        #expect(recovery.tick(connected: false, at: start + 105) == .reconnect)
        #expect(recovery.nextTry == nil)
        #expect(recovery.tick(connected: false, at: start + 10_000) == .wait)
    }

    @Test func aLinkThatCameBackEndsTheFollowUps() {
        var recovery = LinkRecovery()
        _ = recovery.observe(offline, connected: false, at: start)
        _ = recovery.observe(wifi, connected: false, at: start)
        #expect(recovery.tick(connected: true, at: start + 20) == .wait)
        #expect(recovery.nextTry == nil)
    }

    @Test func watchRedialsOnceWhenTheNetworkReturns() {
        var asked = 0
        var down = true
        let watch = NetworkWatch(needsReconnect: { down }, reconnect: { asked += 1 })
        watch.observe(wifi, at: start)
        watch.observe(offline, at: start + 1)
        watch.observe(wifi, at: start + 2)
        #expect(asked == 1)
        down = false
        watch.stop()
    }
}
