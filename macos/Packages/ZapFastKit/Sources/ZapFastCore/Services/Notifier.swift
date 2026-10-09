import Foundation
import UserNotifications

/// Desktop notifications through Notification Center: one thread per chat,
/// a Reply field and a Mark as Read button, and the chat's picture.
///
/// Which messages deserve one is `AppModel`'s decision (upstream's rules);
/// this type only talks to the system. There is one per process, as
/// Notification Center has one delegate; each notification carries the
/// account it came from, as upstream's `NotificationTarget` does.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// What the person did with a notification.
    public enum Response: Sendable {
        case open(chat: String, message: String)
        case reply(chat: String, message: String, text: String)
        case markRead(chat: String)
    }

    /// Runs on the main actor for every response, with its account.
    public var onResponse: (_ account: String, Response) -> Void = { _, _ in }

    private let center = UNUserNotificationCenter.current()
    nonisolated private static let category = "message"
    nonisolated private static let replyAction = "reply"
    nonisolated private static let readAction = "read"

    override public init() {
        super.init()
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction,
            title: String(localized: "Reply"),
            options: [],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Message")
        )
        let read = UNNotificationAction(identifier: Self.readAction, title: String(localized: "Mark as Read"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reply, read], intentIdentifiers: []),
        ])
    }

    public func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func post(
        account: String, chat: String, message: String, title: String, body: String, picture: URL?,
        sound: UNNotificationSound?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.threadIdentifier = Self.thread(account: account, chat: chat)
        content.categoryIdentifier = Self.category
        content.userInfo = ["account": account, "chat": chat, "message": message]
        if let picture, let attachment = Self.attachment(copying: picture) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(
            identifier: "\(Self.thread(account: account, chat: chat))/\(message)", content: content, trigger: nil
        ))
    }

    /// Takes a chat's notifications out of Notification Center once it is read.
    public func clear(account: String, chat: String) {
        let thread = Self.thread(account: account, chat: chat)
        Task {
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == thread }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Takes all of an account's notifications away.
    public func clearAll(account: String) {
        Task {
            let ids = await center.deliveredNotifications()
                .filter { Self.account(of: $0.request.content.userInfo) == account }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// A chat's thread. Account 1's threads keep the chat's id alone, as they
    /// had before there were several accounts.
    nonisolated static func thread(account: String, chat: String) -> String {
        account == "1" ? chat : "\(account)|\(chat)"
    }

    /// Notifications from before there were several accounts are account 1's.
    nonisolated private static func account(of info: [AnyHashable: Any]) -> String {
        info["account"] as? String ?? "1"
    }

    /// The system moves an attachment's file, so it gets a copy.
    private static func attachment(copying url: URL) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "zapfast-notification-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)")
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "picture", url: copy)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // AppModel already skips the chat being read; anything else shows.
        [.banner, .sound, .list]
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let chat = info["chat"] as? String, let message = info["message"] as? String else { return }
        let account = Self.account(of: info)
        let result: Response? = switch response.actionIdentifier {
        case Self.replyAction:
            (response as? UNTextInputNotificationResponse).map {
                .reply(chat: chat, message: message, text: $0.userText)
            }
        case Self.readAction:
            .markRead(chat: chat)
        case UNNotificationDefaultActionIdentifier:
            .open(chat: chat, message: message)
        default:
            nil
        }
        guard let result else { return }
        await MainActor.run { onResponse(account, result) }
    }
}

/// One account's view of the process's notifier.
public struct AccountNotifier {
    public let notifier: Notifier
    public let account: String

    public init(notifier: Notifier, account: String) {
        self.notifier = notifier
        self.account = account
    }

    func post(chat: String, message: String, title: String, body: String, picture: URL?, sound: UNNotificationSound?) {
        notifier.post(
            account: account, chat: chat, message: message, title: title, body: body, picture: picture, sound: sound
        )
    }

    func clear(chat: String) { notifier.clear(account: account, chat: chat) }
    func clearAll() { notifier.clearAll(account: account) }
}
