import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct GroupTests {
    private func model() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-group-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        return (model, backend)
    }

    private func group(
        admin: Bool = false, infoLocked: Bool? = nil, left: Bool = false,
        participants: [String] = [], channel: Bool = false, readOnly: Bool = false
    ) -> ChatSummary {
        ChatSummary(
            id: "g@g.us", name: "Team", groupSubjectKnown: true, kind: channel ? .broadcast : .group,
            lastActivity: 1, unread: 0, markedUnread: false, archived: false, pinned: false, pinnedAt: 0,
            mutedUntil: nil, last: nil, favorite: false, favoritePosition: 0, participants: participants,
            readOnly: readOnly, left: left, infoLocked: infoLocked, admin: admin, locked: false,
            ephemeralExpiration: nil, labels: [], hasCustomSound: false, isChannel: channel,
            looksUnread: false, phone: nil
        )
    }

    @Test func groupInfoIsEditableOnlyWhenWhatsAppAllowsIt() {
        #expect(!group().canEditInfo, "unknown until the metadata says")
        #expect(group(infoLocked: false).canEditInfo)
        #expect(!group(infoLocked: true).canEditInfo)
        #expect(group(admin: true, infoLocked: true).canEditInfo)
        #expect(!group(admin: true, left: true).canEditInfo)
    }

    @Test func leavingFollowsUpstream() {
        let me = ["me@s.whatsapp.net"]
        #expect(group().canLeave(ours: me), "no member list yet")
        #expect(!group(participants: ["x@s.whatsapp.net"]).canLeave(ours: me))
        #expect(group(participants: ["me@s.whatsapp.net"]).canLeave(ours: me))
        #expect(!group(left: true).canLeave(ours: me))
        #expect(!group(channel: true, readOnly: true).canLeave(ours: me))
    }

    @Test func renamingIgnoresBlankAndUnchangedNamesAndWaitsForTheLastChange() {
        let (model, backend) = model()
        let chat = group(infoLocked: false)
        model.renameGroup(chat, to: "  ")
        model.renameGroup(chat, to: "Team")
        model.renameGroup(chat, to: " Crew ")
        model.apply([.groupSaving(chat: "g@g.us", saving: true)])
        model.renameGroup(chat, to: "Squad")
        #expect(backend.sent == [.setGroupName(chat: "g@g.us", name: "Crew")])
    }

    @Test func contactNamesComposeAsUpstreamDoes() {
        #expect(ContactName.compose(first: " Ali ", last: "Valiyev")! == ("Ali Valiyev", "Ali"))
        #expect(ContactName.compose(first: "", last: "Valiyev")! == ("Valiyev", nil))
        #expect(ContactName.compose(first: " ", last: "") == nil)

        let (model, backend) = model()
        model.saveContact("5@s.whatsapp.net", first: "Ali", last: "")
        #expect(backend.sent.last == .saveContact(id: "5@s.whatsapp.net", fullName: "Ali", firstName: "Ali", toPhone: true))
    }

    @Test func groupPhotosAreACentredSquareAtMost640() throws {
        let context = CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let jpeg = try PictureEncoding.squareJPEG(context.makeImage()!)

        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 640)
        #expect(decoded.height == 640)
    }
}
