import SwiftUI
import UniformTypeIdentifiers
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Chooses how chats look (WhatsApp's "Chat theme"): a preset, our
/// bubbles' colour, and the wallpaper, with a live preview. `chat` nil
/// edits the default every chat follows; a chat id edits that chat's own.
/// Every change applies at once.
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
        VStack(alignment: .leading, spacing: Metrics.l) {
            ThemePreview(theme: ChatTheme(appearance, photos: model.themes), detailed: true)
                .frame(height: 170)
                .clipShape(.rect(cornerRadius: Metrics.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(.separator))

            section("Themes") {
                ScrollView(.horizontal) {
                    HStack(spacing: Metrics.s) {
                        ForEach(ThemePresets.all) { preset in
                            Button { apply(preset.appearance) } label: {
                                ThemePreview(theme: ChatTheme(preset.appearance, photos: model.themes), detailed: false)
                                    .frame(width: 72, height: 112)
                                    .clipShape(.rect(cornerRadius: Metrics.controlRadius))
                                    .overlay(selectionRing(preset.appearance == appearance))
                            }
                            .buttonStyle(.plain)
                            .help(preset.name)
                            .accessibilityLabel(preset.name)
                            .accessibilityAddTraits(preset.appearance == appearance ? .isSelected : [])
                        }
                    }
                    .padding(Metrics.xxs)
                }
                .scrollIndicators(.never)
                Text("The chat bubble and wallpaper both change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            section("Chat bubble") {
                HStack(spacing: Metrics.s) {
                    ForEach(ThemePresets.bubbles, id: \.self) { color in
                        swatch(color, selected: color == appearance.bubble) {
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

            section("Wallpaper") {
                wallpaperChoices(appearance)
                wallpaperDetail(appearance)
            }
        }
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

    // MARK: Wallpaper

    private func wallpaperChoices(_ appearance: ChatAppearance) -> some View {
        let current = appearance.wallpaper
        let color = currentColor(appearance)
        let options: [(String, WallpaperStyle)] = [
            (String(localized: "None"), .none),
            (String(localized: "Doodles"), .color(color, doodles: true)),
            (String(localized: "Colour"), .color(color, doodles: false)),
        ] + ThemePresets.gradients.map { ($0.name, WallpaperStyle.gradient($0.id)) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: Metrics.s)], spacing: Metrics.s) {
            ForEach(options, id: \.0) { name, style in
                Button {
                    var changed = appearance
                    changed.wallpaper = style
                    apply(changed)
                } label: {
                    tile(for: style, bubble: appearance.bubble, selected: style == current)
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
            if case .photo = current {
                tile(for: current, bubble: appearance.bubble, selected: true)
                    .accessibilityLabel("Your photo")
            }
            Button { importing = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.controlRadius).fill(.fill.tertiary)
                    Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 96)
            }
            .buttonStyle(.plain)
            .help("Choose Photo…")
            .accessibilityLabel("Choose Photo…")
        }
    }

    @ViewBuilder
    private func wallpaperDetail(_ appearance: ChatAppearance) -> some View {
        switch appearance.wallpaper {
        case let .color(color, doodles):
            VStack(alignment: .leading, spacing: Metrics.s) {
                Text(scheme == .dark ? "Colour in dark appearance" : "Colour in light appearance")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: Metrics.xs)], spacing: Metrics.xs) {
                    ForEach(WallpaperColors.choices(dark: scheme == .dark), id: \.hex) { choice in
                        let side = scheme == .dark ? color.dark : color.light
                        swatch(ThemeColor(choice.hex), selected: side == choice.hex, size: 24) {
                            var picked = color
                            if scheme == .dark { picked.dark = choice.hex } else { picked.light = choice.hex }
                            var changed = appearance
                            changed.wallpaper = .color(picked, doodles: doodles)
                            apply(changed)
                        }
                        .help(choice.name)
                    }
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
            }
        case .none, .gradient:
            EmptyView()
        }
    }

    /// The wallpaper colour the doodles and colour choices start from.
    private func currentColor(_ appearance: ChatAppearance) -> ThemeColor {
        if case .color(let color, _) = appearance.wallpaper { return color }
        return ThemePresets.whatsAppWallpaper
    }

    private func tile(for style: WallpaperStyle, bubble: ThemeColor, selected: Bool) -> some View {
        ThemePreview(theme: ChatTheme(ChatAppearance(bubble: bubble, wallpaper: style), photos: model.themes), detailed: false)
            .frame(width: 64, height: 96)
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))
            .overlay(selectionRing(selected))
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(title).font(.headline)
            content()
        }
    }

    private func selectionRing(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Metrics.controlRadius)
            .strokeBorder(selected ? Color.primary : Color(nsColor: .separatorColor), lineWidth: selected ? 2.5 : 1)
            .overlay(alignment: .bottom) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black)
                        .font(.title3)
                        .padding(Metrics.xs)
                }
            }
    }

    private func swatch(_ color: ThemeColor, selected: Bool, size: CGFloat = 28, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color.dynamic(light: color.light, dark: color.dark))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.separator))
                .overlay {
                    if selected {
                        Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-4)
                    }
                }
                .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The system colour panel, for a bubble colour outside the presets.
    private func customBubble(_ appearance: ChatAppearance) -> Binding<Color> {
        Binding(
            get: { Color.dynamic(light: appearance.bubble.light, dark: appearance.bubble.dark) },
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

    private func apply(_ appearance: ChatAppearance) {
        model.themes.set(appearance, for: chat)
    }
}

/// A theme at a glance: its wallpaper and two bubbles; `detailed` shows
/// readable sample messages, as WhatsApp's preview does.
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
            VStack(spacing: detailed ? Metrics.s : Metrics.xs) {
                bubble(outgoing: false, text: String(localized: "Hi! How does this look? 🎨"), width: 0.62)
                bubble(outgoing: true, text: String(localized: "Only you see your chat themes."), width: 0.5)
            }
            .padding(detailed ? Metrics.m : Metrics.s)
            .padding(.top, detailed ? Metrics.s : Metrics.m)
        }
        .accessibilityHidden(!detailed)
    }

    private func bubble(outgoing: Bool, text: String, width: CGFloat) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 0) }
            Group {
                if detailed {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(outgoing ? theme.outgoingText : Color.primary)
                        .padding(.horizontal, Metrics.m)
                        .padding(.vertical, Metrics.s)
                } else {
                    Color.clear.frame(width: 38, height: 14)
                }
            }
            .background(
                outgoing ? theme.outgoing : theme.incoming,
                in: .rect(cornerRadius: detailed ? Metrics.bubbleRadius : 6, style: .continuous)
            )
            .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
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
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Chat Theme for \(model.chats.chat(chat).map(model.chats.title(for:)) ?? "")")
                .font(.headline)
            ScrollView {
                ChatThemeEditor(chat: chat, model: model)
                    .padding(.trailing, Metrics.s)
            }
            HStack {
                Button("Use Default Theme") {
                    model.themes.useDefault(for: chat)
                }
                .disabled(!model.themes.hasOwnAppearance(chat))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.l)
        .frame(width: 520, height: 640)
    }
}
