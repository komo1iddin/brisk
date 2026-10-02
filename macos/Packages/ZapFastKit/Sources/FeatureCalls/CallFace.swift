import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Who a call is with, as the panel names and pictures it: the person, or
/// the group for a group call. While the app lock is closed, nobody.
@MainActor
enum CallFace {
    static func name(_ call: CallInfo, model: AppModel) -> String {
        if model.appLock.isLocked { return String(localized: "WhatsApp Call") }
        return name(of: call.chat, model: model)
    }

    static func name(of chat: String, model: AppModel) -> String {
        if let summary = model.chats.chat(chat), summary.kind == .group {
            return model.chats.title(for: summary)
        }
        return model.chats.displayName(chat)
    }

    /// "Aziza is calling", for a group call that rings; nil otherwise.
    static func caller(_ call: CallInfo, model: AppModel) -> String? {
        guard call.group, let caller = call.caller, !model.appLock.isLocked else { return nil }
        return String(localized: "\(model.chats.displayName(caller)) is calling")
    }

    /// "Aziza, Bekzod and 2 more" for those in a group call, or who is
    /// being rung while nobody is in yet.
    static func participants(_ call: CallInfo, model: AppModel) -> String? {
        guard call.group, !model.appLock.isLocked, !call.participants.isEmpty else { return nil }
        let joined = call.participants.filter(\.joined)
        let shown = joined.isEmpty ? call.participants : joined
        let names = shown.prefix(2).map { model.chats.displayName($0.chat) }
        let list = shown.count > 2
            ? String(localized: "\(names.joined(separator: ", ")) and \(shown.count - 2) more")
            : names.formatted(.list(type: .and))
        return joined.isEmpty ? String(localized: "Ringing \(list)") : list
    }
}

struct CallAvatar: View {
    let call: CallInfo
    let model: AppModel
    let size: CGFloat

    var body: some View {
        if model.appLock.isLocked {
            AvatarView(url: nil, seed: "call", placeholder: .symbol("phone.fill"), size: size)
        } else if let summary = model.chats.chat(call.chat) {
            ChatAvatar(chat: summary, model: model, size: size)
        } else {
            AvatarView(
                url: model.avatars.url(for: call.chat),
                seed: call.chat,
                placeholder: call.group ? .symbol("person.2.fill") : .initials(model.chats.displayName(call.chat)),
                size: size,
                version: model.avatars.version(for: call.chat)
            )
        }
    }
}
