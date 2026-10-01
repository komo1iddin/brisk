import AppKit
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// A file in a drawn bubble, as `DocumentContent` shows it: the first page
/// on white when there is one (the sender's preview, or a PDF's cover once
/// it is here), then the kind's badge as WhatsApp draws it, its name, and
/// its pages, size and extension; a download arrow or a spinner until it is
/// here. A click opens it in Quick Look or downloads it.
final class DocumentView: AttachmentView {
    private(set) var documentLayout: BubbleLayout.DocumentLayout?

    private let card = CALayer()
    private let page = CALayer()
    private let pageImage = CALayer()
    private let divider = CALayer()
    private let icon = CALayer()
    private let texts = PiecesLayer()
    private let arrow = SymbolLayer()
    private let spinner = NSProgressIndicator()
    private var color = NSColor.labelColor
    private var download: DownloadState?
    private var loads = 0
    private var pagePicture: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.masksToBounds = true
        card.cornerRadius = Metrics.controlRadius
        card.cornerCurve = .continuous
        page.masksToBounds = true
        page.backgroundColor = NSColor.white.cgColor
        page.addSublayer(pageImage)
        page.addSublayer(divider)
        pageImage.contentsGravity = .resizeAspectFill
        icon.contentsGravity = .resizeAspect
        // The page inside the card, whose rounded corners clip it.
        card.addSublayer(page)
        for sublayer in [card, icon, texts, arrow] as [CALayer] { layer?.addSublayer(sublayer) }
        for sublayer in [card, page, pageImage, divider, icon, texts, arrow] as [CALayer] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    func configure(_ layout: BubbleLayout.DocumentLayout, messageID: String, color: NSColor) {
        let sameMessage = messageID == self.messageID
        let same = sameMessage && layout.document == documentLayout?.document && layout.preview?.width == documentLayout?.preview?.width
        self.messageID = messageID
        documentLayout = layout
        self.color = color
        let bounds = CGRect(origin: .zero, size: layout.frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = bounds
        page.isHidden = layout.preview == nil
        if let preview = layout.preview {
            page.frame = preview
            divider.frame = CGRect(x: 0, y: preview.height - 1, width: preview.width, height: 1)
        }
        icon.frame = layout.icon
        texts.frame = bounds
        texts.pieces = [layout.name, layout.detail]
        arrow.frame = layout.indicator ?? .zero
        CATransaction.commit()
        texts.setNeedsDisplay()
        spinner.frame = layout.indicator.map { $0.insetBy(dx: 0.5, dy: 0.5) } ?? .zero
        icon.contents = Self.icon(for: layout.document, scale: window?.backingScaleFactor ?? 2)
        if !same { loadPage(keepingShown: sameMessage) }
        refreshIndicator()
        applyAppearance()
    }

    func setDownload(_ state: DownloadState?) {
        download = state
        refreshIndicator()
    }

    private func refreshIndicator() {
        let waiting = documentLayout?.indicator != nil
        let downloading = waiting && download == .downloading
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.isHidden = !waiting || downloading
        CATransaction.commit()
        if downloading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        arrow.configure(symbol: "arrow.down.circle", pointSize: 15, weight: .regular, palette: [color])
    }

    func refreshColors() {
        applyAppearance()
        texts.setNeedsDisplay()
        arrow.setNeedsDisplay()
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = TimelineText.faded(AppKitPalette.quoteBar, 0.5).cgColor
            divider.backgroundColor = NSColor.separatorColor.cgColor
        }
        texts.appearance = effectiveAppearance
        arrow.appearance = effectiveAppearance
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [texts, arrow] as [CALayer] {
            layer.contentsScale = scale
            layer.setNeedsDisplay()
        }
        if let document = documentLayout?.document { icon.contents = Self.icon(for: document, scale: scale) }
    }

    // MARK: The first page

    /// A PDF that is here draws sharper than the sender's small preview,
    /// which stays until the PDF is drawn.
    private func loadPage(keepingShown: Bool) {
        guard let layout = documentLayout, let id = messageID, let preview = layout.preview else {
            showPage(nil)
            return
        }
        loads += 1
        let load = loads
        let document = layout.document
        let tall = preview.width * 1.5
        let size = CGSize(width: preview.width, height: tall)
        let file = document.path.flatMap { document.isPDF ? URL(filePath: $0) : nil }
        let key = "document-\(id)"
        if let file, let cached = Thumbnails.cachedDocument(file, size: size) {
            showPage(cached)
            return
        }
        if file == nil, let cached = Thumbnails.cached(key: key, points: tall) {
            showPage(cached)
            return
        }
        if keepingShown {
            placePage()
        } else {
            showPage(nil)
        }
        let thumbnail = document.thumbnail
        Task { [weak self] in
            var image: NSImage?
            if let file {
                image = await Thumbnails.document(file, size: size)
            }
            if image == nil, let thumbnail {
                image = await Thumbnails.load(thumbnail, key: key, points: tall)
            }
            guard let self, self.loads == load else { return }
            self.showPage(image)
        }
    }

    /// Full width, top first, as `DocumentContent` fills its page.
    private func showPage(_ image: NSImage?) {
        pagePicture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageImage.contents = pagePicture
        CATransaction.commit()
        placePage()
    }

    private func placePage() {
        guard let pagePicture, let preview = documentLayout?.preview, pagePicture.width > 0 else { return }
        let height = preview.width * CGFloat(pagePicture.height) / CGFloat(pagePicture.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageImage.frame = CGRect(x: 0, y: 0, width: preview.width, height: height.rounded())
        CATransaction.commit()
    }

    override var dragImage: NSImage? {
        guard let document = documentLayout?.document else { return nil }
        return FileIcons.icon(fileName: document.fileName, mime: document.mime)
    }

    /// The file's icon leaves from where it is drawn.
    override var dragFrame: CGRect { documentLayout?.icon ?? bounds }

    /// The kind's badge, as WhatsApp draws it, at the display's scale, kept
    /// per extension and type.
    private static var icons: [String: Any] = [:]

    private static func icon(for document: BubbleSource.Document, scale: CGFloat) -> Any? {
        let key = "\((document.fileName as NSString).pathExtension.lowercased())|\(document.mime)@\(scale)"
        if let icon = icons[key] { return icon }
        let image = FileIcons.badge(fileName: document.fileName, mime: document.mime)
        image.size = NSSize(width: TimelineGeometry.documentIcon, height: TimelineGeometry.documentIcon)
        let contents = image.layerContents(forContentsScale: scale)
        icons[key] = contents
        return contents
    }
}

/// The card under a message's text for the link in it, as
/// `LinkPreviewCard` shows it: the page's picture, its title, a line about
/// it and where it is. A click opens the link.
final class LinkPreviewView: NSView {
    weak var cell: BubbleCell?
    private(set) var previewLayout: BubbleLayout.LinkPreviewLayout?
    private var messageID: String?
    private let card = CALayer()
    private let image = CALayer()
    private let texts = PiecesLayer()
    private var loads = 0
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        card.cornerRadius = Metrics.controlRadius
        card.cornerCurve = .continuous
        image.cornerRadius = 6
        image.cornerCurve = .continuous
        image.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        for sublayer in [card, image, texts] as [CALayer] {
            layer?.addSublayer(sublayer)
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func configure(_ layout: BubbleLayout.LinkPreviewLayout, messageID: String) {
        let same = messageID == self.messageID && layout.preview == previewLayout?.preview
        self.messageID = messageID
        previewLayout = layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = CGRect(origin: .zero, size: layout.frame.size)
        image.frame = layout.image ?? .zero
        image.isHidden = layout.image == nil
        texts.frame = card.frame
        texts.pieces = [layout.title, layout.description, layout.host].compactMap { $0 }
        CATransaction.commit()
        texts.setNeedsDisplay()
        applyAppearance()
        if !same { loadImage() }
    }

    private func loadImage() {
        guard let layout = previewLayout, let id = messageID, let thumbnail = layout.preview.thumbnail else {
            image.contents = nil
            return
        }
        loads += 1
        let load = loads
        let key = "preview-\(id)"
        let points = TimelineGeometry.linkImage
        if let cached = Thumbnails.cached(key: key, points: points) {
            image.contents = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return
        }
        image.contents = nil
        Task { [weak self] in
            let loaded = await Thumbnails.load(thumbnail, key: key, points: points)
            guard let self, self.loads == load else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.image.contents = loaded?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            CATransaction.commit()
        }
    }

    func refreshColors() {
        applyAppearance()
        texts.setNeedsDisplay()
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = TimelineText.faded(AppKitPalette.quoteBar, 0.5).cgColor
        }
        texts.appearance = effectiveAppearance
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        texts.contentsScale = window?.backingScaleFactor ?? 2
        texts.setNeedsDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            cell?.mouseDown(with: event)
            return
        }
        pressed = true
    }

    /// Opens on release inside the card, as a button does, so a press
    /// that slides off it opens nothing.
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              let link = previewLayout.flatMap({ URL(string: $0.preview.url) }) else { return }
        cell?.delegate?.open(link)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu(for: event)
    }
}
