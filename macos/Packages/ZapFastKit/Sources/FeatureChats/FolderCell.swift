/// The folder rows above the chats, and the layer-backed row they draw in.

import AppKit
import Observation
import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign
import ZapFastSharedUI

/// Archived or Locked Chats above the chats, drawn as the chats are: the
/// symbol and count vibrant, the name not.
final class FolderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarFolderCellDrawn")

    private let vibrant = RowLayerView(vibrant: true)
    private let plain = RowLayerView(vibrant: false)
    private let vibrantText = FolderRowLayer(pass: .vibrant)
    private let plainText = FolderRowLayer(pass: .plain)
    private(set) var folderID: String?
    private var open: () -> Void = {}
    /// Only the symbol, centred, in the collapsed sidebar.
    var compact = false

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(vibrant)
        addSubview(plain)
        vibrant.layer?.addSublayer(vibrantText)
        plain.layer?.addSublayer(plainText)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func show(id: String, title: String, systemImage: String, count: Int?, open: @escaping () -> Void) {
        folderID = id
        self.open = open
        let content = FolderRowLayer.Content(
            title: compact ? "" : title, systemImage: systemImage,
            count: compact ? nil : count.flatMap { $0 > 0 ? $0 : nil }, centred: compact
        )
        guard content != plainText.content else { return }
        for layer in [vibrantText, plainText] {
            layer.content = content
            layer.setNeedsDisplay()
        }
        setAccessibilityLabel(content.count.map { "\(title), \($0)" } ?? title)
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        vibrant.frame = bounds
        plain.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vibrantText.frame = bounds
        plainText.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for layer in [vibrantText, plainText] {
            layer.appearance = effectiveAppearance
            layer.setNeedsDisplay()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for layer in [vibrantText, plainText] {
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.setNeedsDisplay()
        }
    }
}

/// Holds a cell's drawn layers; the vibrant one lets AppKit blend them with
/// the sidebar behind, as it does secondary labels.
final class RowLayerView: NSView {
    private let vibrant: Bool

    init(vibrant: Bool) {
        self.vibrant = vibrant
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var allowsVibrancy: Bool { vibrant }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Drawing
