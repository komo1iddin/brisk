import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

extension View {
    /// The group invite sheet (upstream's "Group invite" dialog), shown
    /// whenever the model holds an invite.
    public func groupInviteSheet(model: AppModel) -> some View {
        modifier(GroupInviteModifier(model: model))
    }

    /// Opens WhatsApp group invite links in the app, other links as usual.
    public func opensInviteLinks(model: AppModel) -> some View {
        environment(\.openURL, OpenURLAction { url in
            model.openInviteLink(url) ? .handled : .systemAction
        })
    }
}

private struct GroupInviteModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: $model.invite) { invite in
            GroupInviteSheet(invite: invite, model: model)
        }
    }
}

private struct GroupInviteSheet: View {
    let invite: GroupInvite
    let model: AppModel
    @State private var link = ""
    @State private var badLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Label("Group Invite", systemImage: "person.3").font(.headline)
            content
        }
        .padding(Metrics.l)
        .frame(width: 400)
    }

    @ViewBuilder private var content: some View {
        switch invite.state {
        case .entering:
            Text("Paste a group invite link, such as chat.whatsapp.com/…")
                .foregroundStyle(.secondary)
            TextField("Invite link", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitLink)
                .onChange(of: link) { badLink = false }
            if badLink {
                Text("That isn't a WhatsApp group invite link.").foregroundStyle(.red).font(.callout)
            }
            buttons(primary: "Look Up", enabled: !link.isEmpty, action: submitLink)
        case .loading:
            HStack(spacing: Metrics.s) {
                ProgressView().controlSize(.small)
                Text("Looking up the group…").foregroundStyle(.secondary)
            }
            buttons(primary: nil, enabled: false) {}
        case .ready(let info), .joining(let info):
            details(info)
            let joining = if case .joining = invite.state { true } else { false }
            let member = model.isMember(of: info)
            buttons(
                primary: member ? "Open Chat" : info.approval ? "Request to Join" : "Join Group",
                enabled: !joining && (member || model.session.isConnected),
                busy: joining,
                action: model.acceptInvite
            )
        case .failed(let error):
            Text(error).fixedSize(horizontal: false, vertical: true)
            buttons(primary: nil, enabled: false, cancel: "Close") {}
        }
    }

    private func details(_ info: InviteInfo) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(info.subject).font(.title3.weight(.semibold))
            Text(info.members == 1 ? "1 member" : "\(info.members) members")
                .foregroundStyle(.secondary)
            if let description = info.description, !description.isEmpty {
                ScrollView {
                    Text(description)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            if info.approval, !model.isMember(of: info) {
                Label("An admin must approve your request before you join.", systemImage: "person.badge.clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func buttons(
        primary: LocalizedStringKey?,
        enabled: Bool,
        busy: Bool = false,
        cancel: LocalizedStringKey = "Cancel",
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(cancel, role: .cancel) { model.cancelInvite() }
                .keyboardShortcut(.cancelAction)
            if let primary {
                Button(primary, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled)
            }
        }
    }

    private func submitLink() {
        badLink = !model.submitInviteLink(link)
    }
}
