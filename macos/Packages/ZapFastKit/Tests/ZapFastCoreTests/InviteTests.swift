import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct InviteTests {
    private let code = "AbCdEf1234567890XyZ"
    private let group = "g@g.us"

    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-invite-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.link(state: .connected)])
        return (model, backend)
    }

    private var info: InviteInfo {
        InviteInfo(id: group, subject: "Team", description: nil, members: 3, approval: false)
    }

    @Test func onlyInviteLinksOpenHere() {
        let (model, backend) = model()
        #expect(!model.openInviteLink(URL(string: "https://example.com/AbCdEf1234567890XyZ")!))
        #expect(!model.openInviteLink(URL(string: "https://chat.whatsapp.com.evil.example/\(code)")!))
        #expect(model.invite == nil)

        #expect(model.openInviteLink(URL(string: "https://chat.whatsapp.com/invite/\(code)")!))
        #expect(model.invite?.state == .loading)
        #expect(backend.sent.last == .previewInvite(code: code))
    }

    @Test func aPastedLinkIsLookedUp() {
        let (model, backend) = model()
        model.askForInviteLink()
        #expect(model.invite?.state == .entering)
        #expect(!model.submitInviteLink("hello"))
        #expect(model.submitInviteLink("  https://chat.whatsapp.com/\(code)  "))
        #expect(backend.sent.last == .previewInvite(code: code))
    }

    @Test func joiningOpensTheGroup() {
        let (model, backend) = model()
        model.openInviteLink(URL(string: "https://chat.whatsapp.com/\(code)")!)
        model.apply([.invitePreview(code: "other", info: info, error: nil)])
        #expect(model.invite?.state == .loading, "an answer for another link is ignored")
        model.apply([.invitePreview(code: code, info: info, error: nil)])
        #expect(model.invite?.state == .ready(info))

        model.acceptInvite()
        #expect(backend.sent.last == .joinInvite(code: code))
        #expect(model.invite?.state == .joining(info))

        model.apply([.inviteJoined(code: code, chat: group, pending: false, error: nil)])
        #expect(model.invite == nil)
        #expect(model.selectedChatID == group)
    }

    @Test func aRequestAwaitingApprovalSaysSo() {
        let (model, _) = model()
        model.openInviteLink(URL(string: "https://chat.whatsapp.com/\(code)")!)
        model.apply([.invitePreview(code: code, info: info, error: nil)])
        model.acceptInvite()
        model.apply([.inviteJoined(code: code, chat: group, pending: true, error: nil)])
        #expect(model.invite == nil)
        #expect(model.selectedChatID == nil)
        #expect(model.notices.last?.kind == .info)
    }

    @Test func failuresStayInTheSheet() {
        let (model, _) = model()
        model.openInviteLink(URL(string: "https://chat.whatsapp.com/\(code)")!)
        model.apply([.invitePreview(code: code, info: nil, error: "This link was reset.")])
        #expect(model.invite?.state == .failed("This link was reset."))
    }
}
