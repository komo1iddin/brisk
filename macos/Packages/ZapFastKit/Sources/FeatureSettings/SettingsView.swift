import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// The Settings window. A grouped `Form` is the platform's own shape for
/// preferences, so it stays one.
public struct SettingsView: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.appLock.isLocked {
                // Settings stay behind the app lock with everything else.
                ContentUnavailableView(
                    "ZapFast Is Locked",
                    systemImage: "lock.fill",
                    description: Text("Unlock ZapFast in its window to change settings.")
                )
                .frame(height: 220)
            } else {
                TabView {
                    Tab("Account", systemImage: "person.crop.circle") {
                        AccountSettings(model: model)
                    }
                    Tab("Chats", systemImage: "bubble.left.and.bubble.right") {
                        ChatSettings(preferences: model.preferences, model: model)
                    }
                    Tab("Appearance", systemImage: "paintpalette") {
                        ChatThemeEditor(chat: nil, model: model)
                            .frame(height: 560)
                    }
                    Tab("Privacy", systemImage: "lock") {
                        PrivacySettings(model: model)
                    }
                    Tab("Advanced", systemImage: "gearshape") {
                        AdvancedSettings(model: model)
                    }
                }
            }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct AccountSettings: View {
    let model: AppModel
    @State private var confirmUnlink = false
    @State private var name = ""
    @State private var about = ""
    @State private var choosingPicture = false

    var body: some View {
        let account = model.session.account
        Form {
            Section {
                HStack(spacing: Metrics.m) {
                    AvatarView(
                        url: account.flatMap { model.avatars.fullURL(for: $0.id) ?? model.avatars.url(for: $0.id) },
                        seed: account?.id ?? "",
                        placeholder: .initials(account?.name ?? ""),
                        size: 56,
                        version: account.map { model.avatars.version(for: $0.id) } ?? 0
                    )
                    VStack(alignment: .leading, spacing: Metrics.xxs) {
                        Text(account?.name ?? String(localized: "Linked device")).font(.headline)
                        Text(account.flatMap { phoneOf(id: $0.id) } ?? "").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change Picture…") { choosingPicture = true }
                        .disabled(!model.session.isConnected)
                }
                LabeledContent("Status", value: status)
            }
            Section {
                TextField("Your name", text: limited($name, to: AppModel.profileNameLimit))
                TextField("About", text: limited($about, to: AppModel.aboutLimit))
            } footer: {
                HStack {
                    Text("Shown to people you chat with.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { model.saveProfile(name: name, about: about) }
                        .disabled(!changed || !model.session.isConnected)
                }
            }
            Section {
                Button("Unlink This Mac…", role: .destructive) { confirmUnlink = true }
                    .disabled(!model.isLinked)
            } footer: {
                Text("Unlinking removes this Mac from your phone's linked devices. Messages already copied here stay in the local archive.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Unlink this Mac?", isPresented: $confirmUnlink) {
            Button("Unlink", role: .destructive) { model.unlink() }
        }
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.setProfilePicture(from: url) }
        }
        // Follows the account as the phone reports it, including after a save.
        .onChange(of: account, initial: true) {
            name = account?.name ?? ""
            about = account?.about ?? ""
        }
    }

    private var changed: Bool {
        let account = model.session.account
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmedName.isEmpty && trimmedName != account?.name)
            || about.trimmingCharacters(in: .whitespacesAndNewlines) != (account?.about ?? "")
    }

    /// Stops typing at upstream's length limit.
    private func limited(_ text: Binding<String>, to limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) })
    }

    private var status: String {
        switch model.session.link {
        case .connected: String(localized: "Connected")
        case .connecting, .starting: String(localized: "Connecting")
        case .disconnected: String(localized: "Offline, reconnecting")
        case .unlinked: String(localized: "Not linked")
        case .loggedOut: String(localized: "Unlinked by the phone")
        case .failed: String(localized: "Failed")
        }
    }
}

private struct ChatSettings: View {
    @Bindable var preferences: Preferences
    let model: AppModel
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section {
                Toggle("Download media automatically", isOn: $preferences.autoDownload)
            } footer: {
                Text("Photos, videos, voice messages and documents download when they scroll into view, up to 64 MB each. Stickers always do.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Slider(value: $preferences.textScale, in: 0.8...1.6, step: 0.1) {
                    Text("Text size")
                } minimumValueLabel: {
                    Text(verbatim: "A").font(.caption)
                } maximumValueLabel: {
                    Text(verbatim: "A").font(.title2)
                }
            } footer: {
                Text("Messages and the message field. View › Bigger (⌘+) and Smaller (⌘−) change it too, and Actual Size (⌘0) resets it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Download to") {
                    HStack(spacing: Metrics.s) {
                        let folder = model.downloadFolderInUse
                        Label {
                            Text(preferences.downloadFolder == nil
                                ? String(localized: "ZapFast's cache")
                                : FileManager.default.displayName(atPath: folder.path(percentEncoded: false)))
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                        .help(folder.path(percentEncoded: false))
                        Menu {
                            Button("Choose Folder…") { choosingFolder = true }
                            Button("Show in Finder") {
                                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([folder])
                            }
                            if preferences.downloadFolder != nil {
                                Divider()
                                Button("Use ZapFast's Cache") { model.setDownloadFolder(nil) }
                            }
                        } label: {
                            Text("Change")
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("New downloads go here. Files already downloaded stay where they are. Save As… in a message's menu saves a copy anywhere.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result { model.setDownloadFolder(folder) }
            }
            Section {
                Toggle("Return sends", isOn: $preferences.enterSends)
            } footer: {
                Text(preferences.enterSends
                    ? "Shift-Return or Option-Return starts a new line."
                    : "Return starts a new line; Command-Return sends.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Show profile photos on voice messages", isOn: $preferences.voiceAvatars)
            } footer: {
                Text("The photo of whoever recorded the message sits beside its player, as on the phone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Notifications") {
                Toggle("Show notifications for new messages", isOn: $preferences.notifications)
                Toggle("Show sender and message", isOn: $preferences.notificationPreviews)
                    .disabled(!preferences.notifications)
            }
            Section {
                SoundPicker(title: "New message", sound: $preferences.messageSound)
                SoundPicker(title: "Mention or reply to you", sound: $preferences.mentionSound)
                Toggle("Sounds for group messages", isOn: $preferences.groupSounds)
            } header: {
                Text("Sounds")
            } footer: {
                Text("A chat can have its own sound, from its menu. Mentions of you sound even in quiet groups.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!preferences.notifications)
            Section {
                Toggle("Send read receipts", isOn: $preferences.sendReadReceipts)
                Toggle("Show when you are typing", isOn: $preferences.sendTyping)
            } footer: {
                Text("When off, people don't see blue ticks or played voice messages from this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Save contacts to the phone too", isOn: $preferences.saveContactsToPhone)
            } footer: {
                Text("Names you save here are also added to your phone's address book.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AdvancedSettings: View {
    let model: AppModel

    @State private var proxy = ""
    @State private var proxyProblem: String?
    @FocusState private var editingProxy: Bool
    @State private var loginItem = LoginItem.state
    @State private var loginItemProblem: String?

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginItem != .off },
                    set: { on in
                        loginItemProblem = LoginItem.set(on)
                        loginItem = LoginItem.state
                    }
                ))
                Toggle("Show in menu bar", isOn: $preferences.menuBarIcon)
                Toggle("Keep running when the window closes", isOn: $preferences.keepRunning)
            } header: {
                Text("System")
            } footer: {
                Group {
                    if let loginItemProblem {
                        Text(loginItemProblem).foregroundStyle(.red)
                    } else if loginItem == .needsApproval {
                        HStack(spacing: Metrics.xs) {
                            Text("Allow ZapFast under Login Items to open it at login.")
                            Button("Open Login Items") { LoginItem.openSystemSettings() }
                                .buttonStyle(.link)
                        }
                    } else {
                        Text("Running in the background keeps ZapFast linked for notifications. Quit from the menu bar icon or with ⌘Q.")
                    }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { loginItem = LoginItem.state }
            Section {
                TextField("Proxy", text: $proxy, prompt: Text(verbatim: "socks5h://127.0.0.1:9050"))
                    .focused($editingProxy)
                    .onSubmit(applyProxy)
                    .onChange(of: editingProxy) { if !editingProxy { applyProxy() } }
            } footer: {
                Group {
                    if let proxyProblem {
                        Text(proxyProblem).foregroundStyle(.red)
                    } else if preferences.proxy.isEmpty, let environment = proxyInUse() {
                        Text("Using \(environment) from the environment.")
                    } else {
                        Text("For WhatsApp, media, and GIF search: http://, socks5:// or socks5h://, with user:password@ if needed. Changing it reconnects.")
                    }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { proxy = preferences.proxy }
            Section {
                TextField("GIPHY API key", text: $preferences.giphyKey, prompt: Text("Built-in key, if any"))
            } footer: {
                Text("GIF search asks GIPHY with this key. Create a free one at developers.giphy.com.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Log file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.logFile])
                    }
                }
            } footer: {
                Text("The log never contains message text, phone numbers, or keys. Attach it to bug reports.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func applyProxy() {
        proxyProblem = model.setProxy(proxy)
    }
}

/// One notification sound: the named ones, a chosen file, and a preview.
private struct SoundPicker: View {
    let title: LocalizedStringKey
    @Binding var sound: NotificationSoundInfo

    var body: some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(SoundChoice.named, id: \.self) { named in
                    Text(SoundChoice.title(named)).tag(Optional(named))
                }
                if case .custom = sound {
                    Text(SoundChoice.title(sound)).tag(Optional(sound))
                }
                Divider()
                Text("Choose File…").tag(NotificationSoundInfo?.none)
            }
            Button {
                SoundPlayer.shared.preview(sound)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(sound == .none || sound == .system)
            .help("Play")
            .accessibilityLabel("Play sound")
        }
    }

    /// Nil stands for "Choose File…", which asks and keeps the old sound
    /// when cancelled.
    private var selection: Binding<NotificationSoundInfo?> {
        Binding(
            get: { sound },
            set: { picked in
                if let picked {
                    sound = picked
                } else if let chosen = SoundChoice.chooseFile() {
                    sound = chosen
                }
            }
        )
    }
}
