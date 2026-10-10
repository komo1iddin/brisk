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
                        ChatSettings(model: model, preferences: model.preferences, accountPreferences: model.accountPreferences)
                    }
                    Tab("Notifications", systemImage: "bell.badge") {
                        NotificationSettings(preferences: model.preferences, accountPreferences: model.accountPreferences)
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
        .frame(width: SettingsScreen.width)
    }
}

private struct AccountSettings: View {
    let model: AppModel
    @State private var confirmUnlink = false
    @State private var removing: AppModel?
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
            if let hub = model.hub {
                Section {
                    ForEach(hub.models, id: \.accountID) { account in
                        LabeledContent {
                            if hub.models.count > 1 {
                                Button("Remove…") { removing = account }
                            }
                        } label: {
                            HStack {
                                Text(account.accountTitle)
                                if account === hub.active {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("Add Account…") { hub.addAccount() }
                } header: {
                    Text("Accounts on This Mac")
                } footer: {
                    Text("Switch accounts with your picture at the top of the chat list. Removing an account unlinks it and deletes its messages and files from this Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .settingsPane()
        .confirmationDialog("Unlink this Mac?", isPresented: $confirmUnlink) {
            Button("Unlink", role: .destructive) { model.unlink() }
        }
        .confirmationDialog(
            "Remove \(removing?.accountTitle ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("Remove Account", role: .destructive) { model.hub?.remove(account.accountID) }
        } message: { _ in
            Text("This Mac is unlinked from that account, and its messages, files and settings here are deleted. The phone keeps its chats.")
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
        @Bindable var accountPreferences = model.accountPreferences
        Form {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    Text("System").tag(AppAppearance.system)
                    Text("Light").tag(AppAppearance.light)
                    Text("Dark").tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
            }
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
                Toggle("Download media automatically", isOn: $accountPreferences.autoDownload)
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
        .settingsPane()
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
    @Bindable var accountPreferences: AccountPreferences

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
                Toggle("Show quick reactions above a message's menu", isOn: $preferences.menuReactions)
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
                Picker("Sound when sending", selection: $preferences.sendSound) {
                    Text("Breath").tag(SendSoundStyle.breath)
                    Text("Air").tag(SendSoundStyle.air)
                    Text("Air and Landing").tag(SendSoundStyle.airLanding)
                    Divider()
                    Text("None").tag(SendSoundStyle.none)
                }
                // Choosing one plays it, as the notification sounds do.
                .onChange(of: preferences.sendSound) { _, style in SendSound.play(style) }
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
                Toggle("Save contacts to the phone too", isOn: $accountPreferences.saveContactsToPhone)
            } header: {
                Text("Contacts")
            } footer: {
                Text("Names you save here are also added to your phone's address book.")
                    .settingsFootnote()
            }
        }
        .settingsPane()
    }
}

/// What announces a new message.
private struct NotificationSettings: View {
    @Bindable var preferences: Preferences
    @Bindable var accountPreferences: AccountPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications for new messages", isOn: $accountPreferences.notifications)
                Toggle("Show sender and message", isOn: $preferences.notificationPreviews)
                    .disabled(!accountPreferences.notifications)
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
            .disabled(!accountPreferences.notifications)
        }
        .settingsPane()
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
                LabeledContent("Message archive") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.archiveFile])
                    }
                }
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
        .settingsPane()
    }

    private func applyProxy() {
        proxyProblem = model.setProxy(proxy)
    }
}

extension View {
    /// A Settings tab: a grouped form as tall as what it holds, so the
    /// Settings window takes each tab's own height, as the system's
    /// Settings windows do, and nothing scrolls. On a screen too short for
    /// it the tab stops at the screen's height and the form scrolls.
    ///
    /// The two are separate forms: a form allowed to scroll measured a few
    /// points short in the Settings window and showed a scroll bar with
    /// room to spare, so one that fits cannot scroll at all.
    func settingsPane() -> some View {
        let form = formStyle(.grouped)
        return SettingsPaneHeight(limit: SettingsScreen.paneLimit) {
            ViewThatFits(in: .vertical) {
                form
                    .scrollDisabled(true)
                    .fixedSize(horizontal: false, vertical: true)
                form
            }
        }
    }

    /// The small print under a section.
    func settingsFootnote() -> some View {
        foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Offers its content the screen's limit, never an open height: asked
/// with none, `ViewThatFits` takes its last choice, and a scrolling form's
/// own height is next to nothing. Within the limit the form that fits is
/// as tall as its rows; past it the scrolling one fills the limit.
struct SettingsPaneHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: limit))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// How tall a Settings tab may be on this screen.
enum SettingsScreen {
    /// The Settings window's width, the same for every tab.
    static let width: CGFloat = 560

    /// The screen's height left under the menu bar, less the Settings
    /// window's title bar and tab bar and a margin.
    static var paneLimit: CGFloat {
        #if DEBUG
        // `ZAPFAST_SETTINGS_SCREEN=<points>` stands in for a short screen.
        let override = ProcessInfo.processInfo.environment["ZAPFAST_SETTINGS_SCREEN"].flatMap(Double.init)
        let screen = override.map { CGFloat($0) } ?? NSScreen.main?.visibleFrame.height ?? 900
        #else
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        #endif
        return max(320, screen - 120)
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
            ("chats", AnyView(ChatSettings(model: model, preferences: model.preferences, accountPreferences: model.accountPreferences))),
            ("notifications", AnyView(NotificationSettings(preferences: model.preferences, accountPreferences: model.accountPreferences))),
            ("privacy", AnyView(PrivacySettings(model: model))),
            ("advanced", AnyView(AdvancedSettings(model: model))),
        ]
    }
}
#endif
