/// Linking this account, the profile it shows, and its privacy settings.
///
/// Part of `AppModel`, in a file of its own so that one file is one
/// subject; the state these read and write lives on the class.

import Foundation
import ZapFastBridge

extension AppModel {
    // MARK: Intents: link

    public func pair(phone: String) {
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        backend.send(.pairWithPhone(phone: digits))
    }

    /// Reconnects, or retries starting when the backend never came up. A link
    /// that is down is dialled again now, not when the library's wait ends.
    public func reconnect() {
        guard started else {
            start(verbose: verbose)
            return
        }
        backend.send(.reconnect)
        if session.linkSaysLinked, !session.isConnected { backend.reconnectNow() }
    }
    public func unlink() { backend.send(.unlink) }
    public func startOverArchive() { backend.send(.startOverArchive) }

    /// Whether the person is looking at the app; the phone keeps its push
    /// notifications while they are not.
    public func setActive(_ active: Bool) {
        isActive = active
        guard started, !appLock.isLocked, isOnScreen else { return }
        backend.send(.setOnline(online: active))
        if active, let selectedChatID { notifier?.clear(chat: selectedChatID) }
    }


    func setOnScreen(_ shown: Bool) {
        guard shown != isOnScreen else { return }
        isOnScreen = shown
        if shown {
            guard started, !appLock.isLocked else { return }
            backend.send(.setOnline(online: isActive))
            if isActive, let selectedChatID {
                notifier?.clear(chat: selectedChatID)
                if chats.chat(selectedChatID)?.looksUnread == true { markRead(selectedChatID) }
            }
        } else {
            leaveScreen()
            if started { backend.send(.setOnline(online: false)) }
        }
    }

    // MARK: Intents: our profile

    /// Upstream's limits on our name and About.
    public static let profileNameLimit = 25
    public static let aboutLimit = 139

    /// Sends what changed, as upstream's account settings do: a blank name
    /// keeps the current one; About may be cleared.
    public func saveProfile(name: String, about: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.profileNameLimit))
        let about = String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.aboutLimit))
        let account = session.account
        let changedName = (!name.isEmpty && account?.name != name) ? name : nil
        let changedAbout = ((account?.about ?? "") != about) ? about : nil
        guard changedName != nil || changedAbout != nil else { return }
        backend.send(.setProfile(name: changedName, about: changedAbout))
    }

    public func setProfilePicture(from url: URL) {
        Task {
            do {
                let jpeg = try await PictureEncoding.squareJPEG(from: url)
                backend.send(.setProfilePicture(jpeg: jpeg))
            } catch {
                post(.error, String(localized: "Could not use this picture: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Intents: account privacy

    /// Privacy can change on the phone at any time and nothing announces
    /// it, so Settings asks again each time it shows.
    public func refreshPrivacy() {
        guard session.isConnected else { return }
        backend.send(.fetchAccountPrivacy)
    }

    /// Writes one category, showing it at once; a refusal restores the
    /// phone's value. Nothing is written offline or against stale values.
    public func setPrivacy(_ kind: PrivacyKindInfo, to choice: PrivacyChoiceInfo) {
        guard session.isConnected, privacy.isEditable,
              privacy.snapshot.beginSet(kind: kind, choice: choice) else { return }
        privacy.changed()
        backend.send(.setAccountPrivacy(kind: kind, choice: choice))
    }

    /// The account's read receipts win over the local switch: they are
    /// what the phone and the other linked devices enforce.
    func followReceiptsPrivacy() {
        if let choice = privacy.choice(.readReceipts) {
            session.receiptsDisabled = choice != .everyone
        }
    }
}
