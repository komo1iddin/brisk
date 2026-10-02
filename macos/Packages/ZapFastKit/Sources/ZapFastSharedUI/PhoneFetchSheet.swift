import SwiftUI
import ZapFastCore
import ZapFastDesign

extension View {
    /// The sheet for getting a chat's files and older messages from the phone.
    public func phoneFetchSheet(model: AppModel) -> some View {
        modifier(PhoneFetchModifier(model: model))
    }
}

private struct PhoneFetchModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $model.phoneFetchShown, onDismiss: model.closePhoneFetch) {
            if let fetch = model.phoneFetch {
                PhoneFetchSheet(fetch: fetch, model: model)
            }
        }
    }
}

private struct PhoneFetchSheet: View {
    let fetch: PhoneFetch
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.l) {
            VStack(alignment: .leading, spacing: Metrics.xs) {
                Label("Download from Phone", systemImage: "iphone.and.arrow.forward").font(.headline)
                Text(name).foregroundStyle(.secondary)
            }
            switch fetch.phase {
            case .counting:
                HStack(spacing: Metrics.s) {
                    ProgressView().controlSize(.small)
                    Text("Counting what this Mac has…").foregroundStyle(.secondary)
                }
            case .failed(let error):
                Text("This chat could not be read: \(error)").fixedSize(horizontal: false, vertical: true)
            case .ready:
                history
                Divider()
                files
            }
            HStack {
                if !model.session.isConnected {
                    Label("Not connected to WhatsApp", systemImage: "wifi.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { model.closePhoneFetch() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.l)
        .frame(width: 440)
    }

    private var name: String {
        model.chats.chat(fetch.chat).map(model.chats.title(for:)) ?? String(localized: "this chat")
    }

    // MARK: Older messages

    @ViewBuilder private var history: some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text("Messages").font(.subheadline.weight(.semibold))
            Text(held)
            Text("Your phone sends older messages fifty at a time, and only while it is on and connected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if fetch.history?.state == .asking {
                HStack(spacing: Metrics.s) {
                    ProgressView().controlSize(.small)
                    Text("Loaded \(fetch.history?.loaded ?? 0) earlier messages…")
                    Spacer()
                    Button("Stop") { fetch.stopHistory() }
                }
            } else {
                HStack {
                    if let note = historyNote { Text(note).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Load Earlier Messages") { fetch.startHistory() }
                        .disabled(!model.session.isConnected || fetch.isRunning)
                }
            }
        }
    }

    /// What this Mac has of the chat.
    private var held: String {
        guard let oldest = fetch.oldest else { return String(localized: "This Mac has no messages of this chat yet.") }
        let since = oldest.formatted(.dateTime.day().month(.abbreviated).year())
        return String(localized: "This Mac has \(fetch.messages) messages of this chat, since \(since).")
    }

    private var historyNote: String? {
        guard let history = fetch.history else { return nil }
        let brought = history.loaded
        switch history.state {
        case .asking: return nil
        case .exhausted:
            return brought > 0
                ? String(localized: "Loaded \(brought). Your phone has nothing older.")
                : String(localized: "Your phone has nothing older.")
        case .silent:
            return String(localized: "Your phone did not answer. Open WhatsApp on it and try again.")
        case .offline: return String(localized: "Not connected to WhatsApp.")
        case .stopped: return brought > 0 ? String(localized: "Stopped after \(brought).") : nil
        }
    }

    // MARK: Files

    @ViewBuilder private var files: some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text("Photos, audio and files").font(.subheadline.weight(.semibold))
            ForEach(FetchGroup.allCases, id: \.self) { group in row(group) }
            let large = FetchGroup.allCases.reduce(0) { $0 + (fetch.counts[$1]?.tooLarge ?? 0) }
            if large > 0 {
                Text("\(large) are larger than 64 MB and are skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            progress
        }
    }

    private func row(_ group: FetchGroup) -> some View {
        let counts = fetch.counts[group] ?? .init()
        return Toggle(isOn: Binding(
            get: { fetch.selected.contains(group) && counts.missing > 0 },
            set: { if $0 { fetch.selected.insert(group) } else { fetch.selected.remove(group) } }
        )) {
            HStack {
                Text(title(group))
                Spacer()
                Text(detail(counts)).foregroundStyle(.secondary)
            }
        }
        .disabled(counts.missing == 0 || jobUnderWay)
    }

    /// Files are being fetched, or wait to be: the choice is made.
    private var jobUnderWay: Bool {
        fetch.files.map { $0.running || $0.pause != nil || $0.held > 0 } ?? false
    }

    private func title(_ group: FetchGroup) -> LocalizedStringKey {
        switch group {
        case .photos: "Photos"
        case .videos: "Videos"
        case .audio: "Voice messages and audio"
        case .files: "Files"
        }
    }

    private func detail(_ counts: PhoneFetch.Counts) -> String {
        if counts.total == 0 { return String(localized: "None") }
        var text: String
        if counts.missing == 0 {
            text = counts.unavailable == 0 ? String(localized: "All \(counts.total) are here") : String(localized: "Nothing more to download")
        } else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(counts.missingBytes), countStyle: .file)
            text = String(localized: "\(counts.missing) of \(counts.total) not here · \(size)")
        }
        if counts.unavailable > 0 { text += " · " + String(localized: "\(counts.unavailable) no longer available") }
        return text
    }

    @ViewBuilder private var progress: some View {
        if let job = fetch.files, job.running || job.pause != nil || job.settled > 0 || job.held > 0 {
            VStack(alignment: .leading, spacing: Metrics.s) {
                ProgressView(value: Double(job.settled), total: Double(max(job.total, 1)))
                HStack {
                    Text(status(job)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if job.running, job.pause == nil {
                        Button("Stop") { fetch.stopFiles() }
                    } else if job.pause != nil || job.held > 0 {
                        Button("Try Again") { fetch.resumeFiles() }
                            .disabled(!model.session.isConnected)
                    }
                }
            }
        } else {
            HStack {
                Spacer()
                Button(downloadTitle) { fetch.startFiles() }
                    .disabled(fetch.wanted == 0 || !model.session.isConnected)
            }
        }
    }

    private var downloadTitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(fetch.wantedBytes), countStyle: .file)
        return fetch.wanted == 0
            ? String(localized: "Download")
            : String(localized: "Download \(fetch.wanted) Files (\(size))")
    }

    private func status(_ job: PhoneFetch.FileProgress) -> String {
        var text = String(localized: "\(job.settled) of \(job.total)")
        if job.done > 0, job.done != job.settled { text += " · " + String(localized: "\(job.done) downloaded") }
        if job.gone > 0 { text += " · " + String(localized: "\(job.gone) no longer available") }
        if job.failed > 0 { text += " · " + String(localized: "\(job.failed) failed") }
        switch job.pause {
        case .phoneSilent?:
            text += ". " + String(localized: "Your phone is not answering. Open WhatsApp on it, then try again.")
        case .offline?:
            text += ". " + String(localized: "Not connected to WhatsApp. It goes on when the connection is back.")
        case nil:
            if job.held > 0 {
                text += ". " + String(localized: "\(job.held) could not be fetched from your phone yet.")
            }
        }
        return text
    }
}

#if DEBUG
/// The sheet by itself, over a made-up job, for the debug window.
public func debugPhoneFetchSheet(fetch: PhoneFetch, model: AppModel) -> some View {
    PhoneFetchSheet(fetch: fetch, model: model)
}
#endif
