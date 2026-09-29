import Foundation
import UserNotifications

/// Desktop notifications through Notification Center: one thread per chat,
/// a Reply field and a Mark as Read button, and the chat's picture.
///
/// Which messages deserve one is `AppModel`'s decision (upstream's rules);
/// this type only talks to the system.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// What the person did with a notification.
    public enum Response: Sendable {
        case open(chat: String, message: String)
        case reply(chat: String, message: String, text: String)
        case markRead(chat: String)
    }

    /// Runs on the main actor for every response.
    public var onResponse: (Response) -> Void = { _ in }

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

    public func post(chat: String, message: String, title: String, body: String, picture: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = chat
        content.categoryIdentifier = Self.category
        content.userInfo = ["chat": chat, "message": message]
        if let picture, let attachment = Self.attachment(copying: picture) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: "\(chat)/\(message)", content: content, trigger: nil))
    }

    /// Takes a chat's notifications out of Notification Center once it is read.
    public func clear(chat: String) {
        Task {
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == chat }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    public func clearAll() {
        center.removeAllDeliveredNotifications()
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
        await MainActor.run { onResponse(result) }
    }
}
