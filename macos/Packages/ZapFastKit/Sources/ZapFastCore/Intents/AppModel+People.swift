/// Who a chat is: its info panel, a group's name and members, invites,
/// shared contacts, and the labels this computer puts on chats.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: chat info

    /// Shows the chat's info over it, as a click on its header does, or a
    /// group member's page there, as a click on their name does. The chat's
    /// search stays open beside it.
    public func showInfo(in chat: String? = nil, person: String? = nil) {
        guard let chat = chat ?? selectedChatID else { return }
        infoChat = chat
        infoPerson = person.flatMap { session.isOurs($0) ? nil : $0 }
    }

    public func closeInfo() {
        infoChat = nil
        infoPerson = nil
    }

    // MARK: Intents: groups and contacts

    /// Every id we may be listed under, for `canLeave(ours:)`.
    public var ourIDs: [String] {
        guard let account = session.account else { return [] }
        return [account.id] + (account.lid.map { [$0] } ?? [])
    }

    public func renameGroup(_ chat: ChatSummary, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chat.canEditInfo, !groupSaving.contains(chat.id), !name.isEmpty,
              name != chat.name else { return }
        backend.send(.setGroupName(chat: chat.id, name: name))
    }

    /// Makes a picture file the group's photo, squared and scaled as
    /// upstream does first.
    public func setGroupPicture(_ chat: ChatSummary, from url: URL) {
        guard chat.canEditInfo, !groupSaving.contains(chat.id) else { return }
        Task {
            do {
                let jpeg = try await PictureEncoding.squareJPEG(from: url)
                backend.send(.setGroupPicture(chat: chat.id, jpeg: jpeg))
            } catch {
                post(.error, String(localized: "Could not use this picture: \(error.localizedDescription)"))
            }
        }
    }

    public func removeGroupPicture(_ chat: ChatSummary) {
        guard chat.canEditInfo, !groupSaving.contains(chat.id) else { return }
        backend.send(.setGroupPicture(chat: chat.id, jpeg: nil))
    }

    public func leaveGroup(_ chat: ChatSummary, archive: Bool) {
        guard chat.canLeave(ours: ourIDs) else { return }
        backend.send(.leaveGroup(chat: chat.id, archive: archive))
    }

    /// Saves a person's name through contact sync (upstream's SaveContact).
    public func saveContact(_ id: String, first: String, last: String) {
        guard let name = ContactName.compose(first: first, last: last) else { return }
        backend.send(.saveContact(
            id: id, fullName: name.full, firstName: name.short, toPhone: accountPreferences.saveContactsToPhone
        ))
    }

    // MARK: Intents: group invites

    /// A link was clicked: a WhatsApp group invite opens here (upstream's
    /// rule), anything else is left to the system. Returns whether it was one.
    @discardableResult
    public func openInviteLink(_ url: URL) -> Bool {
        guard let code = groupInviteCode(url: url.absoluteString) else { return false }
        previewInvite(code: code)
        return true
    }

    /// File › Join Group with Link…: the sheet asks for the link.
    public func askForInviteLink() {
        invite = GroupInvite(code: "", state: .entering)
    }

    /// The pasted text, when it is an invite link. Returns whether it was.
    @discardableResult
    public func submitInviteLink(_ text: String) -> Bool {
        guard let code = groupInviteCode(url: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        previewInvite(code: code)
        return true
    }

    private func previewInvite(code: String) {
        invite = GroupInvite(code: code, state: .loading)
        backend.send(.previewInvite(code: code))
    }

    /// Whether the group behind the invite is one we are already in.
    public func isMember(of info: InviteInfo) -> Bool {
        chats.chat(info.id).map { !$0.left } ?? false
    }

    /// Joins, or opens the chat of a group we are already in.
    public func acceptInvite() {
        guard var current = invite, case .ready(let info) = current.state else { return }
        if isMember(of: info) {
            invite = nil
            selectedChatID = info.id
            return
        }
        current.state = .joining(info)
        invite = current
        backend.send(.joinInvite(code: current.code))
    }

    public func cancelInvite() {
        invite = nil
    }

    /// Opens the chat with a person, creating it in the archive first when
    /// there is none yet (upstream's `StartChat`).
    public func startChat(with id: String, name: String? = nil) {
        newChatShown = false
        if chats.chat(id) == nil {
            backend.send(.ensureChat(chat: id, name: name ?? chats.personName(id, hint: nil)))
        }
        selectedChatID = id
    }

    // MARK: Intents: shared contacts

    /// A contact card's name, number and WhatsApp account, read as
    /// upstream's bubble reads it.
    public func sharedContact(in message: MessageRecord) -> SharedContact? {
        guard case let .contact(displayName, vcard) = message.content else { return nil }
        return ZapFastBridge.sharedContact(vcard: vcard, fallbackName: displayName)
    }

    /// The chat id of a shared contact's WhatsApp account.
    public static func chatID(ofAccount account: String) -> String {
        "\(account)@s.whatsapp.net"
    }

    /// The account is already among the contacts WhatsApp knows.
    public func isKnownContact(_ account: String) -> Bool {
        chats.contacts[Self.chatID(ofAccount: account)] != nil
    }

    /// "Message": the chat with the card's account (upstream's StartChat).
    public func chat(with contact: SharedContact) {
        guard let account = contact.account else { return }
        startChat(with: Self.chatID(ofAccount: account), name: contact.name)
    }

    /// "Add": saves the card as a contact, the name split at its first
    /// space as upstream's `split_name` does.
    public func addContact(_ contact: SharedContact) {
        guard let account = contact.account else { return }
        let name = contact.name.trimmingCharacters(in: .whitespaces)
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        newContact(
            phone: account,
            first: parts.first ?? name,
            last: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        )
    }

    // MARK: Intents: labels


    /// Why a label cannot have `name`, or nil (upstream's refusals: the
    /// label limit, and a name another label already has).
    public func labelProblem(name: String, except id: String? = nil) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == nil, chats.labels.count >= Int(labelRules.limit) {
            return String(localized: "You have \(labelRules.limit) labels, the most ZapFast keeps.")
        }
        if chats.labels.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) {
            return String(localized: "A label named “\(name)” already exists.")
        }
        return nil
    }

    public func createLabel(name: String, colorHex: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Int(labelRules.nameLimit)))
        guard !name.isEmpty else { return }
        if let problem = labelProblem(name: name) { return post(.error, problem) }
        backend.send(.createLabel(name: name, colorHex: colorHex))
    }

    public func updateLabel(_ label: LabelInfo, name: String, colorHex: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Int(labelRules.nameLimit)))
        guard !name.isEmpty, name != label.name || colorHex != label.colorHex else { return }
        if let problem = labelProblem(name: name, except: label.id) { return post(.error, problem) }
        backend.send(.updateLabel(id: label.id, name: name, colorHex: colorHex))
    }

    public func deleteLabel(_ label: LabelInfo) {
        backend.send(.deleteLabel(id: label.id))
    }

    /// Puts a label on a chat, or takes it off.
    public func toggleLabel(_ label: String, on chat: ChatSummary) {
        var worn = chat.labels
        if let index = worn.firstIndex(of: label) { worn.remove(at: index) } else { worn.append(label) }
        backend.send(.setChatLabels(chat: chat.id, labels: worn))
    }
}
