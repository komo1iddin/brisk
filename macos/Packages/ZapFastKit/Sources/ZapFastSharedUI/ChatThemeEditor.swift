import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Chooses how chats look, laid out as System Settings › Appearance is: a
/// preview, the themes as labelled thumbnails, the bubble colour as accent
/// swatches, and the wallpaper as a pop-up menu. `chat` nil edits the
/// default every chat follows; a chat id edits that chat's own. Every
/// change applies at once.
public struct ChatThemeEditor: View {
    private let chat: String?
    private let model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var importing = false

    public init(chat: String?, model: AppModel) {
        self.chat = chat
        self.model = model
    }

    public var body: some View {
        let appearance = model.themes.appearance(for: chat)
        Form {
            Section {
                ThemePreview(theme: ChatTheme(appearance, photos: model.themes), detailed: true)
                    .frame(height: 140)
                    .clipShape(.rect(cornerRadius: Metrics.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(.separator))
            }

            Section("Theme") {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metrics.m) {
                        ForEach(ThemePresets.all) { preset in
                            themeThumbnail(preset, selected: preset.appearance == appearance)
                        }
                    }
                    .padding(.vertical, Metrics.xs)
                }
                .scrollIndicators(.never)
            }

            Section {
                LabeledContent("Bubble colour") {
                    bubbleSwatches(appearance)
                }
                Picker("Wallpaper", selection: wallpaperKind(appearance)) {
                    Text("None").tag(WallpaperKind.none)
                    Text("Doodles").tag(WallpaperKind.doodles)
                    Text("Colour").tag(WallpaperKind.colour)
                    Section("Gradients") {
                        ForEach(ThemePresets.gradients) { gradient in
                            Text(gradient.name).tag(WallpaperKind.gradient(gradient.id))
                        }
                    }
                    if case .photo = appearance.wallpaper {
                        Text("Photo").tag(WallpaperKind.photo)
                    }
                }
                wallpaperDetail(appearance)
                LabeledContent("Photo") {
                    Button("Choose…") { importing = true }
                }
            } footer: {
                Text("Themes stay on this Mac. Only you see them.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            Task {
                guard let name = await model.themes.importPhoto(url) else { return }
                var changed = model.themes.appearance(for: chat)
                changed.wallpaper = .photo(name, dim: 0.3)
                apply(changed)
            }
        }
    }

    // MARK: Themes

    private func themeThumbnail(_ preset: ThemePreset, selected: Bool) -> some View {
        Button { apply(preset.appearance) } label: {
            VStack(spacing: Metrics.xs) {
                ThemePreview(theme: ChatTheme(preset.appearance, photos: model.themes), detailed: false)
                    .frame(width: 68, height: 46)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    )
                Text(preset.name)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Bubble colour

    /// The system's multicolour first, as System Settings offers the
    /// accent colour, then the presets and the colour panel.
    private func bubbleSwatches(_ appearance: ChatAppearance) -> some View {
        HStack(spacing: Metrics.s) {
            swatch(fill: AnyShapeStyle(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center
            )), selected: appearance.bubble == nil, help: String(localized: "System accent colour")) {
                var changed = appearance
                changed.bubble = nil
                apply(changed)
            }
            ForEach(ThemePresets.bubbles, id: \.self) { color in
                swatch(fill: AnyShapeStyle(Color.dynamic(light: color.light, dark: color.dark)),
                       selected: appearance.bubble == color, help: nil) {
                    var changed = appearance
                    changed.bubble = color
                    apply(changed)
                }
            }
            ColorPicker("Other colour", selection: customBubble(appearance), supportsOpacity: false)
                .labelsHidden()
                .help("Other colour")
        }
    }

    private func swatch(fill: AnyShapeStyle, selected: Bool, help: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                .overlay {
                    if selected {
                        Circle().fill(.white).frame(width: 6, height: 6)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .accessibilityLabel(help ?? String(localized: "Colour"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The system colour panel, for a bubble colour outside the presets.
    private func customBubble(_ appearance: ChatAppearance) -> Binding<Color> {
        Binding(
            get: { appearance.bubble.map { Color.dynamic(light: $0.light, dark: $0.dark) } ?? .accentColor },
            set: { color in
                guard let hex = NSColor(color).usingColorSpace(.sRGB).map(Self.hex) else { return }
                var changed = model.themes.appearance(for: chat)
                changed.bubble = ThemeColor(hex)
                apply(changed)
            }
        )
    }

    private static func hex(_ color: NSColor) -> String {
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }

    // MARK: Wallpaper

    private enum WallpaperKind: Hashable {
        case none, doodles, colour, photo
        case gradient(String)
    }

    private func wallpaperKind(_ appearance: ChatAppearance) -> Binding<WallpaperKind> {
        Binding(
            get: {
                switch appearance.wallpaper {
                case .none: .none
                case .color(_, let doodles): doodles ? .doodles : .colour
                case .gradient(let id): .gradient(id)
                case .photo: .photo
                }
            },
            set: { kind in
                var changed = appearance
                let colour = currentColor(appearance)
                switch kind {
                case .none: changed.wallpaper = .none
                case .doodles: changed.wallpaper = .color(colour, doodles: true)
                case .colour: changed.wallpaper = .color(colour, doodles: false)
                case .gradient(let id): changed.wallpaper = .gradient(id)
                case .photo: return
                }
                apply(changed)
            }
        )
    }

    /// The colour row for a colour wallpaper (WhatsApp's colours, those of
    /// the appearance in use), or the dimming for a photo.
    @ViewBuilder
    private func wallpaperDetail(_ appearance: ChatAppearance) -> some View {
        switch appearance.wallpaper {
        case let .color(color, doodles):
            let dark = scheme == .dark
            Picker(dark ? "Colour in dark appearance" : "Colour in light appearance", selection: Binding(
                get: { dark ? color.dark : color.light },
                set: { hex in
                    var picked = color
                    if dark { picked.dark = hex } else { picked.light = hex }
                    var changed = appearance
                    changed.wallpaper = .color(picked, doodles: doodles)
                    apply(changed)
                }
            )) {
                ForEach(colourChoices(dark: dark, current: dark ? color.dark : color.light), id: \.hex) { choice in
                    Label {
                        Text(verbatim: choice.name)
                    } icon: {
                        ColorSwatch.image(hex: choice.hex)
                    }
                    .tag(choice.hex)
                }
            }
        case let .photo(name, dim):
            LabeledContent("Dim in dark appearance") {
                Slider(value: Binding(
                    get: { dim },
                    set: { value in
                        var changed = appearance
                        changed.wallpaper = .photo(name, dim: value)
                        apply(changed)
                    }
                ), in: 0...0.8)
                .frame(maxWidth: 200)
            }
        case .none, .gradient:
            EmptyView()
        }
    }

    /// Upstream's colours, with WhatsApp's default first when it is in use.
    private func colourChoices(dark: Bool, current: String) -> [WallpaperColorInfo] {
        let whatsApp = WallpaperColorInfo(
            name: String(localized: "WhatsApp"),
            hex: dark ? ThemePresets.whatsAppWallpaper.dark : ThemePresets.whatsAppWallpaper.light
        )
        let list = WallpaperColors.choices(dark: dark)
        return list.contains { $0.hex == whatsApp.hex } ? list : [whatsApp] + list
    }

    /// The wallpaper colour the doodles and colour choices start from.
    private func currentColor(_ appearance: ChatAppearance) -> ThemeColor {
        if case .color(let color, _) = appearance.wallpaper { return color }
        return ThemePresets.whatsAppWallpaper
    }

    private func apply(_ appearance: ChatAppearance) {
        model.themes.set(appearance, for: chat)
    }
}

/// A theme at a glance: its wallpaper and two bubbles; `detailed` shows
/// readable sample messages.
public struct ThemePreview: View {
    private let theme: ChatTheme
    private let detailed: Bool

    public init(theme: ChatTheme, detailed: Bool) {
        self.theme = theme
        self.detailed = detailed
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .textBackgroundColor)
            WallpaperView(theme.wallpaper)
            VStack(spacing: detailed ? Metrics.s : 3) {
                bubble(outgoing: false, text: String(localized: "Hi! How does this look?"))
                bubble(outgoing: true, text: String(localized: "Only you see your chat themes."))
            }
            .padding(detailed ? Metrics.m : 6)
        }
        .accessibilityHidden(!detailed)
    }

    private func bubble(outgoing: Bool, text: String) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 0) }
            Group {
                if detailed {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(outgoing ? theme.outgoingText : Color.primary)
                        .padding(.horizontal, Metrics.m)
                        .padding(.vertical, 6)
                } else {
                    Color.clear.frame(width: 30, height: 9)
                }
            }
            .background(
                outgoing ? theme.outgoing : theme.incoming,
                in: .rect(cornerRadius: detailed ? Metrics.bubbleRadius : 4, style: .continuous)
            )
            .shadow(color: .black.opacity(theme.hasWallpaper ? 0.08 : 0), radius: 0.5, y: 0.5)
            if !outgoing { Spacer(minLength: 0) }
        }
    }
}

// MARK: - Presenting it for one chat

extension View {
    /// The chat theme sheet a chat's menu opens.
    public func chatThemeSheet(model: AppModel) -> some View {
        modifier(ChatThemeSheetModifier(model: model))
    }
}

private struct ChatThemeSheetModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.themeEditorChat.map(ThemeTarget.init) },
            set: { model.themeEditorChat = $0?.id }
        )) { target in
            ChatThemeSheet(chat: target.id, model: model)
        }
    }
}

private struct ThemeTarget: Identifiable {
    let id: String
}

private struct ChatThemeSheet: View {
    let chat: String
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ChatThemeEditor(chat: chat, model: model)
            Divider()
            HStack {
                Button("Use Default Theme") { model.themes.useDefault(for: chat) }
                    .disabled(!model.themes.hasOwnAppearance(chat))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Metrics.l)
        }
        .frame(width: 520, height: 620)
        .navigationTitle(model.chats.chat(chat).map(model.chats.title(for:)) ?? "")
    }
}
