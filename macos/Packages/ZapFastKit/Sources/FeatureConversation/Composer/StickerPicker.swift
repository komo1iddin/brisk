import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Stickers and GIFs, in a popover over the composer. Emoji come from the
/// system's Character Viewer (Edit › Emoji & Symbols), so they are not
/// repeated here.
struct StickerPicker: View {
    let chatID: String
    let model: AppModel
    let close: () -> Void

    enum Tab: String { case stickers, gifs }
    @AppStorage("stickerPickerTab") private var tab: Tab = .stickers
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: Metrics.s) {
            Picker("Show", selection: $tab) {
                Text("Stickers").tag(Tab.stickers)
                Text("GIFs").tag(Tab.gifs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .gifs, !model.canSearchGifs || model.stickers.gifError?.badKey == true {
                GiphyKeyForm(model: model) { model.searchGifs(query) }
            } else {
                TextField(tab == .stickers ? "Search stickers" : "Search GIPHY", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)

                switch tab {
                case .stickers: stickers
                case .gifs: gifs
                }
            }
        }
        .padding(Metrics.m)
        .frame(width: 360, height: 420)
        .onAppear {
            model.loadStickers()
            if tab == .gifs { model.searchGifs(query) }
            searchFocused = true
        }
        .onChange(of: tab) {
            if tab == .gifs { model.searchGifs(query) }
        }
        .onChange(of: query) {
            if tab == .gifs { model.searchGifs(query) }
        }
    }

    // MARK: Stickers

    @ViewBuilder private var stickers: some View {
        if let library = model.stickers.library {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = trimmed.isEmpty ? [] : model.stickers.search(trimmed)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.m, pinnedViews: .sectionHeaders) {
                    if trimmed.isEmpty {
                        shelf(Text("Favorites"), library.favorites)
                        shelf(Text("Recent"), library.recent)
                        ForEach(library.packs, id: \.dir) { pack in
                            shelf(Text(verbatim: pack.name), pack.stickers)
                        }
                        shelf(Text("Sent to You"), library.received)
                    } else {
                        shelf(Text("Results"), results)
                    }
                }
            }
            .overlay {
                if trimmed.isEmpty, library.favorites.isEmpty, library.recent.isEmpty,
                   library.packs.isEmpty, library.received.isEmpty {
                    ContentUnavailableView(
                        "No stickers yet",
                        systemImage: "face.smiling",
                        description: Text("Stickers you send or receive show up here.")
                    )
                } else if !trimmed.isEmpty, results.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
        } else {
            ProgressView().frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func shelf(_ title: Text, _ paths: [String]) -> some View {
        if !paths.isEmpty {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: Metrics.s)], spacing: Metrics.s) {
                    ForEach(paths, id: \.self) { path in
                        StickerCell(path: path, model: model) {
                            model.sendSticker(path, in: chatID)
                            close()
                        }
                    }
                }
            } header: {
                title
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Metrics.xxs)
                    .background(.background)
            }
        }
    }

    // MARK: GIFs

    @ViewBuilder private var gifs: some View {
        let store = model.stickers
        if store.gifs.isEmpty {
            Group {
                if store.gifPending {
                    ProgressView()
                } else if let error = store.gifError {
                    ContentUnavailableView("GIFs unavailable", systemImage: "wifi.exclamationmark",
                                           description: Text(error.message))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: Metrics.s)], spacing: Metrics.s) {
                    ForEach(store.gifs, id: \.id) { gif in
                        GifCell(gif: gif) {
                            model.sendGif(gif, in: chatID)
                            close()
                        }
                    }
                }
            }
            Text("Powered by GIPHY")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// One sticker: click sends; the menu files it into or out of Favorites.
private struct StickerCell: View {
    let path: String
    let model: AppModel
    let send: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: send) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(.rect)
        }
        .buttonStyle(PickerCellStyle())
        .task(id: path) { image = await Thumbnails.load(URL(filePath: path), points: 72) }
        .contextMenu {
            Button(model.stickers.isFavorite(path) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: model.stickers.isFavorite(path) ? "star.slash" : "star") {
                model.toggleFavoriteSticker(path)
            }
            if model.stickers.library?.recent.contains(path) == true {
                Button("Remove from Recent", systemImage: "clock.badge.xmark") { model.removeRecentSticker(path) }
            }
        }
        .accessibilityLabel("Sticker")
    }
}

/// A GIF's still frame at its shape; click sends it.
private struct GifCell: View {
    let gif: GifInfo
    let send: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: send) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.controlRadius).fill(.fill.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(height: 80)
            .clipShape(.rect(cornerRadius: Metrics.controlRadius))
            .contentShape(.rect)
        }
        .buttonStyle(PickerCellStyle())
        .task(id: gif.still) {
            if let still = gif.still { image = await Thumbnails.load(URL(filePath: still), points: 110) }
        }
        .accessibilityLabel("GIF")
    }
}

/// A light highlight under the pointer, as in the system's pickers.
private struct PickerCellStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(Metrics.xxs)
            .background(
                RoundedRectangle(cornerRadius: Metrics.controlRadius)
                    .fill(.fill.tertiary)
                    .opacity(configuration.isPressed ? 1 : hovering ? 0.6 : 0)
            )
            .onHover { hovering = $0 }
    }
}

/// Asked in place when GIF search has no key, or GIPHY refused it, as
/// upstream does.
private struct GiphyKeyForm: View {
    let model: AppModel
    let saved: () -> Void
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s) {
            Text(model.stickers.gifError?.badKey == true
                 ? "This GIPHY API key was rejected. Create a free key at developers.giphy.com and paste it here. It is saved in your settings."
                 : "GIF search needs a GIPHY API key. Create a free key at developers.giphy.com and paste it here. It is saved in your settings.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("GIPHY API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Link("developers.giphy.com", destination: URL(string: "https://developers.giphy.com")!)
                    .font(.callout)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .onAppear { key = model.preferences.giphyKey }
    }

    private func save() {
        model.preferences.giphyKey = key.trimmingCharacters(in: .whitespaces)
        saved()
    }
}
