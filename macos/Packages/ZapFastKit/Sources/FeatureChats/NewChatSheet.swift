import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Starts a chat: pick a contact, or type a number WhatsApp then checks.
struct NewChatSheet: View {
    let model: AppModel

    private enum Page { case contacts, number }
    @State private var page = Page.contacts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch page {
            case .contacts: ContactsPage(model: model) { page = .number }
            case .number: NumberPage(model: model) { page = .contacts }
            }
        }
        .padding(Metrics.l)
        .frame(width: 400)
    }
}

/// The contacts, "Message yourself" first as on the phone.
private struct ContactsPage: View {
    let model: AppModel
    let addNumber: () -> Void

    private static let yourself = "\u{0}self"
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let people = model.chats.newChatCandidates(query: query)
        let offerSelf = model.chats.offersSelf(query: query)
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("New Chat").font(.headline)

            TextField("Search contacts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)

            List(selection: $selection) {
                if offerSelf {
                    HStack(spacing: Metrics.s) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Message yourself")
                            Text(model.chats.selfTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Self.yourself)
                }
                ForEach(people, id: \.id) { person in
                    HStack(spacing: Metrics.s) {
                        AvatarView(
                            url: model.avatars.url(for: person.id),
                            seed: person.id,
                            placeholder: .initials(person.name.trimmingPrefix("~").description),
                            size: 28
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            Text(person.name).lineLimit(1)
                            if let phone = PhoneFormat.display(id: person.id) {
                                Text(phone).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(person.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
            .overlay {
                if people.isEmpty, !offerSelf { ContentUnavailableView.search(text: query) }
            }
            .frame(minHeight: 320)

            HStack {
                Button("New Contact…", systemImage: "person.badge.plus", action: addNumber)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Chat") { if let selection { open(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .onAppear { searchFocused = true }
    }

    private func open(_ id: String) {
        if id == Self.yourself { model.messageYourself() } else { model.startChat(with: id) }
    }
}

/// A number with its country code, and an optional name to save it under.
private struct NumberPage: View {
    let model: AppModel
    let back: () -> Void

    @State private var phone = ""
    @State private var first = ""
    @State private var last = ""
    @FocusState private var phoneFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("New Contact").font(.headline)
            Text("Enter a phone number with its country code, without a plus sign or leading zero. Add a name to save the contact, or leave it blank to open the chat. WhatsApp uses the first name as the display name.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: Metrics.s) {
                GridRow {
                    Text("Phone").gridColumnAlignment(.trailing)
                    TextField("998901234567", text: $phone)
                        .focused($phoneFocused)
                        .onChange(of: phone) { phone = phone.filter(\.isNumber) }
                }
                GridRow {
                    Text("First name")
                    TextField("Optional", text: $first)
                }
                GridRow {
                    Text("Last name")
                    TextField("Optional", text: $last)
                }
            }
            .textFieldStyle(.roundedBorder)

            if !first.isEmpty || !last.isEmpty {
                Text(model.preferences.saveContactsToPhone
                     ? "The name is also saved to your phone's contacts."
                     : "The name is saved for WhatsApp only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Back", systemImage: "chevron.backward", action: back)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.newContactPending {
                    ProgressView().controlSize(.small)
                }
                Button("Chat") { model.newContact(phone: phone, first: first, last: last) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phone.isEmpty || model.newContactPending)
            }
        }
        .onAppear { phoneFocused = true }
    }
}
