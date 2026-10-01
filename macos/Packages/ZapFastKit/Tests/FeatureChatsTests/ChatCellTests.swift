import AppKit
import Testing
import ZapFastBridge
@testable import FeatureChats
@testable import ZapFastCore

private let own = "998900000000@s.whatsapp.net"
private let member = "998901112233@s.whatsapp.net"

@MainActor
private func makeModel(_ chats: [ChatSummary]) -> AppModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-chat-cell-\(UUID().uuidString)")
    let model = AppModel(
        backend: PreviewBackend(),
        paths: AppPaths(data: root, caches: root),
        preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
    model.apply([
        .me(id: own, lid: nil, name: "Me", about: nil),
        .contacts(contacts: [ContactRecord(id: member, fullName: "Shahlo Rahimova", firstName: "Shahlo", pushName: nil)]),
        .chats(chats: chats),
    ])
    return model
}

private func chat(
    _ id: String, name: String, kind: ChatKind = .direct, unread: UInt32 = 0, marked: Bool = false,
    muted: Bool = false, pinned: Bool = false, last: ChatPreview? = nil
) -> ChatSummary {
    ChatSummary(
        id: id, name: name, groupSubjectKnown: true, kind: kind, lastActivity: 1_790_000_000,
        unread: unread, markedUnread: marked, archived: false, pinned: pinned, pinnedAt: pinned ? 1 : 0,
        mutedUntil: muted ? 0 : nil, last: last, favorite: false, favoritePosition: 0, participants: [],
        readOnly: false, left: false, infoLocked: nil, admin: false, locked: false, ephemeralExpiration: nil,
        labels: [], hasCustomSound: false, isChannel: kind == .broadcast, looksUnread: unread > 0 || marked, phone: nil
    )
}

private func preview(_ text: String, from sender: String, name: String? = nil, fromMe: Bool = false, status: DeliveryState = .none) -> ChatPreview {
    ChatPreview(fromMe: fromMe, sender: sender, senderName: name, summary: text, full: text, status: status)
}

/// A drawn row shows what `ChatRow` showed.
@MainActor
struct ChatRowContentTests {
    @Test func aGroupsLastMessageNamesItsSenderAndOwnMessagesCarryTicks() {
        let group = chat("1@g.us", name: "Oila", kind: .group, last: preview("Salom", from: member))
        let mine = chat("2@s.whatsapp.net", name: "Jasur", last: preview("Ok", from: own, fromMe: true, status: .read))
        let direct = chat("3@s.whatsapp.net", name: "Bobur", last: preview("Qalesan?", from: "3@s.whatsapp.net"))
        let model = makeModel([group, mine, direct])

        #expect(ChatRowContent(chat: group, model: model).preview == .message("Shahlo Rahimova: Salom", ticks: nil))
        #expect(ChatRowContent(chat: mine, model: model).preview == .message("Ok", ticks: .read))
        #expect(ChatRowContent(chat: direct, model: model).preview == .message("Qalesan?", ticks: nil))
        #expect(ChatRowContent(chat: chat("4@g.us", name: "Bo'sh", kind: .group), model: model).preview == .nothing)
    }

    @Test func typingComesBeforeADraftAndADraftBeforeTheLastMessage() {
        let group = chat("1@g.us", name: "Ishxona", kind: .group, last: preview("Reja", from: member))
        let direct = chat("2@s.whatsapp.net", name: "Kamola", last: preview("Salom", from: "2@s.whatsapp.net"))
        let model = makeModel([group, direct])
        model.apply([.drafts(drafts: [Draft(chat: direct.id, text: "Ertaga")])])
        #expect(ChatRowContent(chat: direct, model: model).preview == .draft("Ertaga"))

        // The open chat's draft is in its composer, not in its row.
        model.selectedChatID = direct.id
        #expect(ChatRowContent(chat: direct, model: model).preview == .message("Salom", ticks: nil))
        model.selectedChatID = nil

        model.apply([
            .typing(chat: direct.id, sender: direct.id, composing: true),
            .typing(chat: group.id, sender: member, composing: true),
        ])
        #expect(ChatRowContent(chat: direct, model: model).preview == .typing("typing…"))
        #expect(ChatRowContent(chat: group, model: model).preview == .typing("Shahlo Rahimova is typing…"))
    }

    @Test func unreadMutedAndPinnedChatsAreMarked() {
        let unread = chat("1@s.whatsapp.net", name: "Bobur", unread: 3)
        let muted = chat("2@g.us", name: "Oila", kind: .group, unread: 128, muted: true, pinned: true)
        let marked = chat("3@s.whatsapp.net", name: "Nodira", marked: true)
        let read = chat("4@s.whatsapp.net", name: "Aziza")
        let model = makeModel([unread, muted, marked, read])

        let first = ChatRowContent(chat: unread, model: model)
        #expect(first.bold && first.timeAccented && first.badge == .count(3))
        let second = ChatRowContent(chat: muted, model: model)
        #expect(second.muted && second.pinned && !second.timeAccented && second.badge == .count(128))
        #expect(ChatRowContent(chat: marked, model: model).badge == .dot)
        let fourth = ChatRowContent(chat: read, model: model)
        #expect(!fourth.bold && fourth.badge == nil && !fourth.muted && !fourth.pinned)
    }

    @Test func placeholdersAreInitialsForPeopleAndSymbolsForGroupsAndChannels() {
        let person = chat("1@s.whatsapp.net", name: "Aziza Karimova")
        let group = chat("2@g.us", name: "Oila", kind: .group)
        let channel = chat("3@newsletter", name: "Yangiliklar", kind: .broadcast)
        let model = makeModel([person, group, channel])
        #expect(ChatRowContent(chat: person, model: model).placeholder == .initials("AK"))
        #expect(ChatRowContent(chat: group, model: model).placeholder == .symbol("person.2.fill"))
        #expect(ChatRowContent(chat: channel, model: model).placeholder == .symbol("megaphone.fill"))
    }
}

@MainActor
struct ChatTableTests {
    private func table(_ rows: [SidebarRow], model: AppModel) -> ChatTableController {
        let controller = ChatTableController()
        controller.makeScrollView().frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        controller.update(rows: rows, selection: nil, model: model) { _ in }
        return controller
    }

    private func cell(_ row: Int, in controller: ChatTableController) -> ChatCell? {
        controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ChatCell
    }

    /// Waits for the main queue to run what observation scheduled.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func aChatThatChangedIsShownAgainInTheSameCell() async {
        var bobur = chat("1@s.whatsapp.net", name: "Bobur", last: preview("Salom", from: "1@s.whatsapp.net"))
        let aziza = chat("2@s.whatsapp.net", name: "Aziza")
        let model = makeModel([bobur, aziza])
        let controller = table([.chat(bobur), .chat(aziza)], model: model)
        let first = cell(0, in: controller)
        #expect(first?.content?.badge == nil)

        bobur.unread = 2
        bobur.looksUnread = true
        model.apply([.chatUpdated(chat: bobur)])
        controller.update(rows: [.chat(bobur), .chat(aziza)], selection: nil, model: model) { _ in }
        #expect(cell(0, in: controller) === first)
        #expect(first?.content?.badge == .count(2))

        // What the cell reads from the model itself, it follows itself.
        model.apply([.typing(chat: bobur.id, sender: bobur.id, composing: true)])
        await settle()
        #expect(first?.content?.preview == .typing("typing…"))
    }

    @Test func aCellWaitingForReuseStopsFollowingTheModel() async {
        let bobur = chat("1@s.whatsapp.net", name: "Bobur", last: preview("Salom", from: "1@s.whatsapp.net"))
        let model = makeModel([bobur])
        let controller = table([.chat(bobur)], model: model)
        let first = cell(0, in: controller)
        first?.stopObserving()
        model.apply([.typing(chat: bobur.id, sender: bobur.id, composing: true)])
        await settle()
        #expect(first?.content?.preview == .message("Salom", ticks: nil))
    }

    @Test func aClickOnAFolderOpensItAndAChatsRowHasItsMessageForATooltip() {
        let bobur = chat("1@s.whatsapp.net", name: "Bobur", last: preview("Qalesan? Ishlar yaxshimi?", from: "1@s.whatsapp.net"))
        let model = makeModel([bobur])
        var opened = 0
        let controller = table([
            .folder(id: "archived", title: "Archived", systemImage: "archivebox", count: 2) { opened += 1 },
            .chat(bobur),
        ], model: model)
        #expect(controller.openFolder(atRow: 0))
        #expect(!controller.openFolder(atRow: 1))
        #expect(opened == 1)
        #expect(controller.toolTip(forRow: 1) == "Qalesan? Ishlar yaxshimi?")
        #expect(controller.toolTip(forRow: 0) == nil)
    }
}
