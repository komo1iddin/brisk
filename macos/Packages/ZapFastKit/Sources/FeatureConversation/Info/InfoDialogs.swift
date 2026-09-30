import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Something the info panel asks of the window. The panel is a popover,
/// which closes first: alerts, sheets and open panels belong to the chat's
/// window, not to a popover over it.
enum InfoRequest: Equatable {
    case rename(ChatSummary)
    case choosePhoto(ChatSummary)
    case leave(ChatSummary)
    case editContact(String)
}

extension View {
    /// The window's side of the info panel's requests.
    func infoDialogs(_ request: Binding<InfoRequest?>, model: AppModel) -> some View {
        modifier(InfoDialogs(request: request, model: model))
    }
}

private struct InfoDialogs: ViewModifier {
    @Binding var request: InfoRequest?
    let model: AppModel
    @State private var newName = ""
    /// The group a photo is being chosen for. The importer answers after
    /// its binding is cleared, so the request alone would be gone by then.
    @State private var photoFor: ChatSummary?

    func body(content: Content) -> some View {
        content
            .alert("Rename Group", isPresented: shown { $0.renaming }, presenting: request?.renaming) { chat in
                TextField("Group name", text: $newName)
                Button("Rename") { model.renameGroup(chat, to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Everyone in the group sees the new name.")
            }
            .fileImporter(isPresented: shown { $0.photoGroup }, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result, let chat = photoFor { model.setGroupPicture(chat, from: url) }
                photoFor = nil
            }
            .confirmationDialog(
                request?.leaving?.isChannel == true ? "Leave this channel?" : "Leave this group?",
                isPresented: shown { $0.leaving },
                presenting: request?.leaving
            ) { chat in
                Button(chat.isChannel ? "Leave Channel" : "Leave Group", role: .destructive) {
                    model.leaveGroup(chat, archive: false)
                }
                if !chat.archived {
                    Button(chat.isChannel ? "Leave Channel and Archive" : "Leave Group and Archive", role: .destructive) {
                        model.leaveGroup(chat, archive: true)
                    }
                }
            } message: { _ in
                Text("You will not receive new messages. The local history stays on this computer.")
            }
            .sheet(isPresented: shown { $0.contact }) {
                if let id = request?.contact { ContactNameSheet(id: id, model: model) }
            }
            .onChange(of: request) {
                if let chat = request?.renaming { newName = chat.name }
                if let chat = request?.photoGroup { photoFor = chat }
            }
    }

    /// Shown while the request is of one kind; dismissing clears it.
    private func shown<Value>(_ kind: @escaping (InfoRequest) -> Value?) -> Binding<Bool> {
        Binding(
            get: { request.flatMap(kind) != nil },
            set: { if !$0, request.flatMap(kind) != nil { request = nil } }
        )
    }
}

private extension InfoRequest {
    var renaming: ChatSummary? { if case .rename(let chat) = self { chat } else { nil } }
    var photoGroup: ChatSummary? { if case .choosePhoto(let chat) = self { chat } else { nil } }
    var leaving: ChatSummary? { if case .leave(let chat) = self { chat } else { nil } }
    var contact: String? { if case .editContact(let id) = self { id } else { nil } }
}

/// A person's name for the address book, first and last, saved through
/// WhatsApp's contact sync (and to the phone when Settings say so).
private struct ContactNameSheet: View {
    let id: String
    let model: AppModel
    @State private var first = ""
    @State private var last = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("First name", text: $first)
                TextField("Last name", text: $last)
            } header: {
                Text(phoneOf(id: id) ?? model.chats.displayName(id))
            } footer: {
                Text(model.preferences.saveContactsToPhone
                     ? "The name is also saved to your phone's contacts."
                     : "The name is saved for WhatsApp only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveContact(id, first: first, last: last)
                    dismiss()
                }
                .disabled(ContactName.compose(first: first, last: last) == nil)
            }
        }
        .onAppear(perform: prefill)
    }

    /// Starts from the saved name, split at its first name when known.
    private func prefill() {
        let contact = model.chats.contacts[id]
        guard let full = contact?.fullName, !full.isEmpty else {
            first = contact?.pushName ?? ""
            return
        }
        if let short = contact?.firstName, !short.isEmpty, full.hasPrefix(short) {
            first = short
            last = String(full.dropFirst(short.count)).trimmingCharacters(in: .whitespaces)
        } else {
            first = full
        }
    }
}
