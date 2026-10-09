import AVFoundation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A chat's photos and videos, one at a time, as WhatsApp shows them: who
/// sent it and when above, with what can be done with it; the picture in
/// the middle with its caption; the chat's media in a strip below, with
/// All Media, reactions, Reply and Done.
///
/// Beyond WhatsApp: photos zoom as in Preview (pinch, double-click, ⌘+ ⌘−
/// ⌘0) and carry Live Text; videos have the Mac's own controls with speed
/// and Picture in Picture; a two-finger swipe, ← → or the strip step
/// through; ⌘C copies the photo and ⌘S saves either; Escape zooms out,
/// then closes. A photo can go straight to the media editor to be marked
/// up and sent.
struct MediaViewerView: View {
    let chatID: String
    @Bindable var model: AppModel

    @State private var currentID: String?
    @State private var showingGrid = false
    @State private var zoom = PhotoZoom()
    @State private var player = AVPlayer()
    @State private var reacting = false
    @State private var confirmingDelete = false
    @State private var captionExpanded = false
    @State private var hoveringStage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var conversation: Conversation { model.conversations.conversation(chatID) }
    private var items: [MessageRecord] { MediaGallery.items(in: conversation.messages) }

    private var current: MessageRecord? {
        let id = currentID ?? model.mediaViewer?.message
        return items.first { $0.id == id }
    }

    private var index: Int? {
        current.flatMap { current in items.firstIndex { $0.id == current.id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 52)
            Divider()
            ZStack {
                if showingGrid {
                    MediaGrid(items: items, model: model, complete: conversation.complete) { message in
                        select(message.id)
                        withAnimation(.zf(reduceMotion)) { showingGrid = false }
                    } loadOlder: {
                        model.loadOlder(in: chatID)
                    }
                    .transition(.opacity)
                } else if let current {
                    stage(current)
                        .id(current.id)
                        .transition(.opacity)
                    navigation
                    caption(current)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onHover { hoveringStage = $0 }
            Divider()
            bottomBar
                .frame(height: 64)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .animation(.zf(reduceMotion, duration: 0.18), value: current?.id)
        .background(EditorKeys(handle: handleKey))
        .onAppear {
            currentID = model.mediaViewer?.message
            prepare(current)
        }
        .onChange(of: current?.id) { _, id in
            captionExpanded = false
            prepare(current)
            #if DEBUG
            if MediaViewerScript.steps != nil { print("script: showing \(id ?? "nothing")") }
            #endif
        }
        #if DEBUG
        .onChange(of: showingGrid) { _, grid in
            if MediaViewerScript.steps != nil { print("script: grid \(grid)") }
        }
        #endif
        .onChange(of: items.map(\.id)) { old, new in
            // The one shown was deleted: show its neighbour, or close.
            guard let id = currentID, !new.contains(id) else { return }
            let position = old.firstIndex(of: id) ?? 0
            if new.isEmpty {
                model.closeMediaViewer()
            } else {
                currentID = new[min(position, new.count - 1)]
            }
        }
        .onDisappear { player.pause() }
        .confirmationDialog(Text("Delete this photo or video?"), isPresented: $confirmingDelete) {
            if let current {
                Button("Delete for Me", role: .destructive) { model.deleteForMe(current) }
                if model.canRevoke(current) {
                    Button("Delete for Everyone", role: .destructive) { model.deleteForEveryone(current) }
                }
            }
        } message: {
            Text("Deleting for you also removes it from your phone and linked devices. It can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Metrics.m) {
            if let current {
                sender(of: current)
            }
            Spacer(minLength: Metrics.l)
            if let current {
                actions(for: current)
            }
        }
        .padding(.leading, 86)
        .padding(.trailing, Metrics.m)
        .background(WindowDragArea())
    }

    private func sender(of message: MessageRecord) -> some View {
        let id = message.fromMe ? (model.session.account?.id ?? message.sender) : message.sender
        let name = message.fromMe
            ? String(localized: "You")
            : model.chats.displayName(message.sender, hint: message.senderName)
        return HStack(spacing: Metrics.s) {
            AvatarView(
                url: model.avatars.url(for: id), seed: id, placeholder: .initials(name), size: 30,
                version: model.avatars.version(for: id)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text(Date(timeIntervalSince1970: TimeInterval(message.timestamp)).formatted(date: .numeric, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(for message: MessageRecord) -> some View {
        let url = message.mediaURL
        HStack(spacing: Metrics.s) {
            if let url {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .viewerButton()
                .help("Share")
            }
            Menu {
                Button("Show in Chat", systemImage: "text.bubble") {
                    model.closeMediaViewer()
                    model.reveal(MessageKey(chat: message.chat, message: message.id))
                }
                if let url {
                    if MediaGallery.kind(of: message) == .photo {
                        Button("Copy Image", systemImage: "doc.on.doc") { AttachmentSaving.copyImage(at: url) }
                    }
                    Button("Open With Default App", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if model.canShowInfo(message) {
                    Button("Info", systemImage: "info.circle") {
                        model.closeMediaViewer()
                        model.showInfo(message)
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .viewerButton()
            .help("More")

            Button { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                .viewerButton()
                .help("Delete")

            if url != nil {
                Button {
                    editAndSend(message)
                } label: {
                    Label("Edit and Send", systemImage: "pencil.and.scribble")
                }
                .viewerButton()
                .help("Mark up and send again")
            }

            if model.canForward(message) {
                Button {
                    model.closeMediaViewer()
                    model.forward(message)
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
                .viewerButton()
                .help("Forward")
            }

            if let url {
                Button { save(message, url) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .viewerButton()
                    .help("Save a copy (⌘S)")
            }
        }
        .labelStyle(.iconOnly)
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(_ message: MessageRecord) -> some View {
        if let url = message.mediaURL {
            switch MediaGallery.kind(of: message) {
            case .photo:
                ZoomablePhoto(url: url, zoom: zoom) { forward in step(forward ? 1 : -1) }
            case .video:
                ViewerVideo(player: player)
            case .gif:
                LoopingVideo(url: url)
                    .aspectRatio(aspect(of: message), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                EmptyView()
            }
        } else {
            PendingMedia(message: message, model: model)
        }
    }

    private func aspect(of message: MessageRecord) -> CGFloat {
        guard let media = message.content.media, let width = media.width, let height = media.height, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    /// Chevrons at the stage's edges while the pointer is over it.
    private var navigation: some View {
        HStack {
            chevron("chevron.left", enabled: (index ?? 0) > 0) { step(-1) }
                .help("Previous (←)")
            Spacer()
            chevron("chevron.right", enabled: (index ?? items.count) < items.count - 1) { step(1) }
                .help("Next (→)")
        }
        .padding(.horizontal, Metrics.m)
        .opacity(hoveringStage ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hoveringStage)
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .modifier(FloatingSurface(Circle()))
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func caption(_ message: MessageRecord) -> some View {
        if let text = MediaGallery.caption(of: message) {
            Text(verbatim: text)
                .font(.body)
                .lineLimit(captionExpanded ? nil : 3)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, Metrics.l)
                .padding(.vertical, Metrics.s + 2)
                .modifier(GlassCard())
                .frame(maxWidth: 620)
                .onTapGesture { withAnimation(.zf(reduceMotion)) { captionExpanded.toggle() } }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, Metrics.l)
                .transition(.opacity)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Metrics.m) {
            Button {
                withAnimation(.zf(reduceMotion)) { showingGrid.toggle() }
            } label: {
                Label(showingGrid ? "Back" : "All Media", systemImage: showingGrid ? "chevron.left" : "square.grid.3x3")
            }
            .viewerBarButton()
            .frame(maxWidth: .infinity, alignment: .leading)

            if !showingGrid {
                MediaStrip(items: items, current: current?.id, model: model, complete: conversation.complete) { id in
                    select(id)
                } loadOlder: {
                    model.loadOlder(in: chatID)
                }
                .frame(maxWidth: 720)
                .layoutPriority(1)
            }

            HStack(spacing: Metrics.s) {
                if let current {
                    Button { reacting.toggle() } label: {
                        Label("React", systemImage: "face.smiling").labelStyle(.iconOnly)
                    }
                    .viewerBarButton()
                    .help("React")
                    .popover(isPresented: $reacting, arrowEdge: .top) {
                        ReactionPicker(
                            quick: model.quickReactions(for: current),
                            mine: current.reactions.first(where: \.fromMe)?.emoji,
                            frequent: model.preferences.reactionEmoji.map(\.emoji)
                        ) { emoji in
                            reacting = false
                            model.react(emoji, to: current)
                        }
                    }
                    Button("Reply") {
                        model.closeMediaViewer()
                        model.reply(to: current)
                    }
                    .viewerBarButton()
                }
                Button("Done") { model.closeMediaViewer() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.l)
    }

    // MARK: Actions

    private func select(_ id: String) {
        guard id != current?.id else { return }
        currentID = id
    }

    private func step(_ offset: Int) {
        guard let index, items.indices.contains(index + offset) else { return }
        select(items[index + offset].id)
        // The strip's start is where older media is asked for.
        if index + offset == 0, !conversation.complete { model.loadOlder(in: chatID) }
    }

    /// Starts a video, stops one left, and fetches what is not here yet.
    private func prepare(_ message: MessageRecord?) {
        guard let message else { return }
        if MediaGallery.kind(of: message) == .video, let url = message.mediaURL {
            if (player.currentItem?.asset as? AVURLAsset)?.url != url {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
            }
            player.play()
        } else {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        if message.mediaURL == nil { model.download(message) }
    }

    private func save(_ message: MessageRecord, _ url: URL) {
        AttachmentSaving.saveCopy(of: url, named: url.lastPathComponent)
    }

    /// The photo or video goes to the media editor of this chat, to be
    /// marked up and sent again.
    private func editAndSend(_ message: MessageRecord) {
        guard let url = message.mediaURL else { return }
        player.pause()
        model.closeMediaViewer()
        model.stage(files: [url], in: chatID)
    }

    private func handleKey(_ key: EditorKeys.Key, inTextField: Bool) -> Bool {
        guard !inTextField, !reacting, !confirmingDelete else { return false }
        switch key {
        case .escape:
            if showingGrid {
                withAnimation(.zf(reduceMotion)) { showingGrid = false }
            } else if zoom.isZoomed {
                zoom.reset()
            } else {
                model.closeMediaViewer()
            }
            return true
        case .left, .right:
            guard !showingGrid else { return false }
            step(key == .left ? -1 : 1)
            return true
        case .space:
            guard let current, MediaGallery.kind(of: current) == .video else { return false }
            if player.rate == 0 { player.play() } else { player.pause() }
            return true
        case .commandC:
            guard let current, MediaGallery.kind(of: current) == .photo, let url = current.mediaURL else { return false }
            AttachmentSaving.copyImage(at: url)
            return true
        case .commandS:
            guard let current, let url = current.mediaURL else { return false }
            save(current, url)
            return true
        case .zoomIn:
            zoom.zoomIn()
            return true
        case .zoomOut:
            zoom.zoomOut()
            return true
        case .zoomReset:
            zoom.reset()
            return true
        default:
            return false
        }
    }
}

// MARK: - Pieces

private extension View {
    /// A round button in the header, all the same size and colour whether
    /// it acts or opens a menu.
    func viewerButton() -> some View {
        menuStyle(.button).buttonStyle(ViewerButtonStyle())
    }

    /// A plain button in the bottom bar: the text's own colour, not the
    /// chat's, which only Done wears.
    func viewerBarButton() -> some View {
        controlSize(.large).buttonStyle(.bordered).tint(.primary)
    }
}

/// A round glass button with the symbol in the text's colour, as WhatsApp's
/// header has them, pressed in when clicked.
private struct ViewerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewerButtonBody(configuration: configuration)
    }
}

private struct ViewerButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        surface(
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
        )
            .contentShape(.circle)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }

    /// Clear Liquid Glass on macOS 26, untinted so the chat's colour stays
    /// on Done; a soft disc before it.
    @ViewBuilder
    private func surface(_ label: some View) -> some View {
        if #available(macOS 26, *) {
            label.glassEffect(.regular.interactive(), in: .circle)
        } else {
            label
                .background(.primary.opacity(configuration.isPressed ? 0.16 : (hovered ? 0.11 : 0.06)), in: .circle)
                .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

/// A photo or video not downloaded yet: its small preview, blurred, with
/// the download's progress, or a retry when it failed.
private struct PendingMedia: View {
    let message: MessageRecord
    let model: AppModel
    @State private var preview: NSImage?

    var body: some View {
        let state = model.conversations.download(MessageKey(chat: message.chat, message: message.id))
        ZStack {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 18)
                    .opacity(0.8)
                    .padding(Metrics.xl)
            }
            Group {
                switch state {
                case .downloading, nil:
                    ProgressView().controlSize(.large)
                case .failed(let reason):
                    VStack(spacing: Metrics.s) {
                        Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again", systemImage: "arrow.clockwise") { model.download(message) }
                    }
                    .padding(Metrics.l)
                    .modifier(GlassCard())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: message.id) {
            guard let thumbnail = message.thumbnail else { return }
            preview = await Thumbnails.load(thumbnail, key: "thumb-\(message.id)", points: 320)
        }
    }
}

/// The small picture of a photo or video: the file once here, else the
/// preview WhatsApp sent with it.
private struct MediaThumbnail: View {
    let message: MessageRecord
    let points: CGFloat
    @State private var image: NSImage?

    var body: some View {
        // The picture fills whatever frame it is given and is cut to it.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
        .task(id: "\(message.id)-\(message.mediaURL?.path ?? "")") {
            if MediaGallery.kind(of: message) == .photo, let url = message.mediaURL {
                image = await Thumbnails.load(url, points: points)
            } else if let thumbnail = message.thumbnail {
                image = await Thumbnails.load(thumbnail, key: "thumb-\(message.id)", points: points)
            }
        }
    }
}

/// The chat's media in a row, the one shown wider and outlined, kept in
/// view as it changes. Reaching the oldest asks for more.
private struct MediaStrip: View {
    let items: [MessageRecord]
    let current: String?
    let model: AppModel
    let complete: Bool
    let select: (String) -> Void
    let loadOlder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(items, id: \.id) { message in
                        let selected = message.id == current
                        MediaThumbnail(message: message, points: 48)
                            .frame(width: selected ? 48 : 30, height: 44)
                            .clipShape(.rect(cornerRadius: 5, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(.tint, lineWidth: selected ? 2 : 0)
                            }
                            .overlay(alignment: .bottomLeading) {
                                if MediaGallery.kind(of: message) != .photo {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 1)
                                        .padding(3)
                                }
                            }
                            .padding(.horizontal, selected ? 4 : 0)
                            .contentShape(.rect)
                            .onTapGesture { select(message.id) }
                            .onAppear {
                                if message.id == items.first?.id, !complete { loadOlder() }
                            }
                            .id(message.id)
                            .animation(.snappy(duration: 0.2), value: selected)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, Metrics.s)
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, id in
                withAnimation(.zf(reduceMotion)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Every photo and video in the chat, newest first, by month.
private struct MediaGrid: View {
    let items: [MessageRecord]
    let model: AppModel
    let complete: Bool
    let open: (MessageRecord) -> Void
    let loadOlder: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                ForEach(MediaGallery.months(of: items), id: \.month) { group in
                    Section {
                        ForEach(group.items.reversed(), id: \.id) { message in
                            MediaThumbnail(message: message, points: 180)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(alignment: .bottomLeading) { badge(message) }
                                .contentShape(.rect)
                                .onTapGesture { open(message) }
                                .onAppear {
                                    if message.id == items.first?.id, !complete { loadOlder() }
                                }
                        }
                    } header: {
                        Text(group.month.formatted(.dateTime.month(.wide).year()))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Metrics.s)
                            .padding(.horizontal, Metrics.xs)
                            .background(.background.opacity(0.95))
                    }
                }
                if !complete {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(Metrics.l)
                        .onAppear(perform: loadOlder)
                }
            }
            .padding(Metrics.l)
        }
    }

    @ViewBuilder
    private func badge(_ message: MessageRecord) -> some View {
        if case .video(_, _, let seconds, let gif, _) = message.content {
            HStack(spacing: 3) {
                Image(systemName: gif ? "livephoto" : "video.fill")
                if let seconds, seconds > 0, !gif {
                    Text(Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(radius: 1.5)
            .padding(5)
        }
    }
}
