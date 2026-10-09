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
                    Tab("General", systemImage: "gearshape") {
                        GeneralSettings(model: model)
                    }
                    Tab("Account", systemImage: "person.crop.circle") {
                        AccountSettings(model: model)
                    }
                    Tab("Chats", systemImage: "bubble.left.and.bubble.right") {
                        ChatSettings(model: model, preferences: model.preferences)
                    }
                    Tab("Notifications", systemImage: "bell.badge") {
                        NotificationSettings(preferences: model.preferences)
                    }
                    Tab("Appearance", systemImage: "paintpalette") {
                        ChatThemeEditor(chat: nil, model: model)
                            .frame(height: 560)
                    }
                    Tab("Privacy", systemImage: "hand.raised") {
                        PrivacySettings(model: model)
                    }
                    Tab("Advanced", systemImage: "gearshape.2") {
                        AdvancedSettings(model: model)
                    }
                }
            }
        }
        .frame(width: 560)
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
                        Text(account.flatMap { PhoneFormat.display(id: $0.id) } ?? "").foregroundStyle(.secondary)
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
        .settingsPane(height: 400)
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

/// How ZapFast runs on this Mac, and where its files go.
private struct GeneralSettings: View {
    let model: AppModel
    @State private var loginItem = LoginItem.state
    @State private var loginItemProblem: String?
    @State private var choosingFolder = false

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
                .settingsFootnote()
            }
            .onAppear { loginItem = LoginItem.state }

            Section {
                Toggle("Download media automatically", isOn: $preferences.autoDownload)
                LabeledContent("Download to") {
                    DownloadFolderControl(model: model, choosing: $choosingFolder)
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Photos, videos, voice messages and documents download as they scroll into view, up to 64 MB each; stickers always do. Files already downloaded stay where they are.")
                    .settingsFootnote()
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result { model.setDownloadFolder(folder) }
            }
        }
        .settingsPane(height: 360)
    }
}

/// The download folder by name, and a menu to change it.
private struct DownloadFolderControl: View {
    let model: AppModel
    @Binding var choosing: Bool

    /// The Finder's folder icon at menu size.
    private static let folderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    var body: some View {
        let folder = model.downloadFolderInUse
        let custom = model.preferences.downloadFolder != nil
        Menu {
            Button("Choose Folder…") { choosing = true }
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            if custom {
                Divider()
                Button("Use ZapFast's Cache") { model.setDownloadFolder(nil) }
            }
        } label: {
            Label {
                Text(custom
                    ? FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
                    : String(localized: "ZapFast's cache"))
            } icon: {
                Image(nsImage: Self.folderIcon)
            }
        }
        .fixedSize()
        .help(folder.path(percentEncoded: false))
    }
}

/// Reading and writing messages.
private struct ChatSettings: View {
    let model: AppModel
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Slider(value: $preferences.textScale, in: 0.8...1.6, step: 0.1) {
                    Text("Text size")
                } minimumValueLabel: {
                    Text(verbatim: "A").font(.caption)
                } maximumValueLabel: {
                    Text(verbatim: "A").font(.title3)
                }
                Toggle("Show profile photos on voice messages", isOn: $preferences.voiceAvatars)
                Toggle("Show the numbers of people not in your contacts in groups", isOn: $preferences.senderPhones)
            } header: {
                Text("Messages")
            } footer: {
                Text("Text size is also in View › Bigger (⌘+), Smaller (⌘−) and Actual Size (⌘0).")
                    .settingsFootnote()
            }
            Section {
                Toggle("Return sends", isOn: $preferences.enterSends)
            } header: {
                Text("Writing")
            } footer: {
                Text(preferences.enterSends
                    ? "Shift-Return or Option-Return starts a new line."
                    : "Return starts a new line; Command-Return sends.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Keep chats archived", isOn: Binding(
                    get: { preferences.keepChatsArchived },
                    set: { model.setKeepChatsArchived($0) }
                ))
            } header: {
                Text("Archive")
            } footer: {
                Text("When off, a new message brings an archived chat back to the list.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Save contacts to the phone too", isOn: $preferences.saveContactsToPhone)
            } header: {
                Text("Contacts")
            } footer: {
                Text("Names you save here are also added to your phone's address book.")
                    .settingsFootnote()
            }
        }
        .settingsPane(height: 540)
    }
}

/// What announces a new message.
private struct NotificationSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
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
                    .settingsFootnote()
            }
            .disabled(!preferences.notifications)
        }
        .settingsPane(height: 320)
    }
}

private struct AdvancedSettings: View {
    let model: AppModel

    @State private var proxy = ""
    @State private var proxyProblem: String?
    @FocusState private var editingProxy: Bool

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                TextField("Proxy", text: $proxy, prompt: Text(verbatim: "socks5h://127.0.0.1:9050"))
                    .focused($editingProxy)
                    .onSubmit(applyProxy)
                    .onChange(of: editingProxy) { if !editingProxy { applyProxy() } }
            } header: {
                Text("Network")
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
                .settingsFootnote()
            }
            .onAppear { proxy = preferences.proxy }
            Section {
                TextField("GIPHY API key", text: $preferences.giphyKey, prompt: Text("Built-in key, if any"))
            } footer: {
                Text("GIF search asks GIPHY with this key. Create a free one at developers.giphy.com.")
                    .settingsFootnote()
            }
            Section {
                LabeledContent("Log file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.logFile])
                    }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("The log never contains message text, phone numbers, or keys. Attach it to bug reports.")
                    .settingsFootnote()
            }
        }
        .settingsPane(height: 350)
    }

    private func applyProxy() {
        proxyProblem = model.setProxy(proxy)
    }
}

extension View {
    /// A Settings tab: a grouped form at a set height that scrolls when its
    /// content is taller, so the window never outgrows the screen.
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped).frame(height: height)
    }

    /// The small print under a section.
    func settingsFootnote() -> some View {
        foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

#if DEBUG
/// Settings tabs for the debug snapshot, which draws each in a window of
/// its own. The account tab stays out: it shows the person's name and
/// number.
public enum SettingsDebug {
    public static func panes(model: AppModel) -> [(name: String, view: AnyView)] {
        [
            ("general", AnyView(GeneralSettings(model: model))),
            ("chats", AnyView(ChatSettings(model: model, preferences: model.preferences))),
            ("notifications", AnyView(NotificationSettings(preferences: model.preferences))),
            ("privacy", AnyView(PrivacySettings(model: model))),
            ("advanced", AnyView(AdvancedSettings(model: model))),
        ]
    }
}
#endif
