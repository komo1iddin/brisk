import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A business message (upstream's interactive card): its image, text and
/// buttons, or a strip of carousel cards. Quick replies and list choices
/// send a response; links open, and copy-code buttons copy, locally.
struct InteractiveContent: View {
    let message: MessageRecord
    let text: String
    let card: InteractiveCardInfo?
    let model: AppModel

    var body: some View {
        if let card {
            VStack(alignment: .leading, spacing: Metrics.s) {
                if let image = card.image {
                    CardImage(message: message, media: image, thumbnail: card.thumbnail, card: nil, model: model)
                }
                if !card.body.isEmpty {
                    BodyText(text: card.body, message: message, model: model)
                }
                if !card.carousel.isEmpty {
                    Carousel(message: message, cards: card.carousel, model: model)
                }
                if !card.buttons.isEmpty {
                    ButtonList(message: message, buttons: card.buttons, sends: true, model: model)
                }
                if card.needsPhone {
                    Label("More content in WhatsApp Web or on your phone", systemImage: "iphone")
                        .font(.caption)
                        .opacity(0.75)
                }
            }
            .frame(minWidth: 220, alignment: .leading)
        } else {
            BodyText(text: text, message: message, model: model)
        }
    }
}

/// The buttons under a card, one per row as on the phone.
private struct ButtonList: View {
    let message: MessageRecord
    let buttons: [InteractiveButtonInfo]
    /// Carousel cards' reply choices are not supported, as upstream's aren't.
    let sends: Bool
    let model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                Divider().opacity(0.6)
                let problem = problem(button)
                Button {
                    press(button, index: index)
                } label: {
                    Label(button.label, systemImage: symbol(button))
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metrics.s)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(problem == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .disabled(problem != nil)
                .help(problem.map { "\(button.label)\n\($0)" } ?? hint(button))
            }
        }
    }

    private func symbol(_ button: InteractiveButtonInfo) -> String {
        if button.url != nil { return "arrow.up.forward.square" }
        switch button.action {
        case .reply: return "arrowshape.turn.up.left"
        case .copy: return "doc.on.doc"
        case .select: return "list.bullet"
        case .unavailable: return "iphone"
        }
    }

    /// Why the button is off, or nil.
    private func problem(_ button: InteractiveButtonInfo) -> String? {
        if button.url != nil { return nil }
        switch button.action {
        case .copy: return nil
        case .reply, .select:
            guard sends else { return String(localized: "Open this option in WhatsApp Web or on your phone") }
            return model.answerProblem(message)
        case .unavailable:
            return String(localized: "Open this option in WhatsApp Web or on your phone")
        }
    }

    private func hint(_ button: InteractiveButtonInfo) -> String {
        if let url = button.url { return url }
        switch button.action {
        case .reply: return String(localized: "Send reply: \(button.label)")
        case .copy: return String(localized: "Copy code")
        default: return button.label
        }
    }

    private func press(_ button: InteractiveButtonInfo, index: Int) {
        if let link = button.url, let url = URL(string: link) {
            openURL(url)
            return
        }
        switch button.action {
        case .reply:
            model.answer(message, button: index)
        case .select:
            model.showChoices(message, button: index)
        case .copy(let code):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        case .unavailable:
            break
        }
    }
}

/// Carousel cards side by side, each with its own image and buttons.
private struct Carousel: View {
    let message: MessageRecord
    let cards: [CarouselCardInfo]
    let model: AppModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Metrics.s) {
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    VStack(alignment: .leading, spacing: Metrics.s) {
                        if let image = card.image {
                            CardImage(message: message, media: image, thumbnail: card.thumbnail, card: index, model: model)
                        }
                        if !card.body.isEmpty {
                            BodyText(text: card.body, message: message, model: model)
                                .padding(.horizontal, Metrics.s)
                        }
                        ButtonList(message: message, buttons: card.buttons, sends: false, model: model)
                    }
                    .frame(width: 220, alignment: .topLeading)
                    .background(Palette.quoteBar.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
                    .clipShape(.rect(cornerRadius: Metrics.controlRadius))
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: 460)
    }
}

/// A card's picture: its preview until downloaded, then the file; a
/// click opens it in Quick Look.
private struct CardImage: View {
    let message: MessageRecord
    let media: MediaInfo
    let thumbnail: Data?
    let card: Int?
    let model: AppModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            if media.path == nil, state == .downloading {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: Metrics.controlRadius))
        .contentShape(.rect)
        .onTapGesture {
            if let path = media.path { QuickLook.shared.show([URL(filePath: path)]) } else { download() }
        }
        .task(id: "\(message.id)-\(card ?? -1)-\(media.path ?? "")") {
            if let path = media.path {
                image = await Thumbnails.load(URL(filePath: path), points: 280)
            } else if let thumbnail {
                image = await Thumbnails.load(thumbnail, key: "card-\(message.id)-\(card ?? -1)", points: 280)
            }
            if media.path == nil, model.preferences.autoDownload, state == nil { download() }
        }
    }

    private var state: DownloadState? {
        let key = MessageKey(chat: message.chat, message: message.id)
        if let card { return model.conversations.cardDownloads[CardKey(message: key, card: card)] }
        return model.conversations.downloads[key]
    }

    private func download() {
        if let card { model.downloadCard(message, card: card) } else { model.download(message) }
    }
}
