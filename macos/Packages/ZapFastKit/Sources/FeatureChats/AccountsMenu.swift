import AppKit
import ZapFastCore

/// The account switcher: our own picture in the sidebar's toolbar, with a
/// dot while another account has unread chats, and a menu of the accounts
/// (picture, name or number, unread chats, a check on the one on screen)
/// and Add Account, as upstream's switcher.
@MainActor
final class AccountsMenu: NSObject, NSMenuDelegate {
    private let hub: AccountHub

    init(hub: AccountHub) {
        self.hub = hub
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for model in hub.models {
            let item = NSMenuItem(title: model.accountTitle, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.accountID
            item.state = model === hub.active ? .on : .off
            item.image = AccountPicture.image(url: model.accountPicture, size: 20, dot: false)
            let unread = model.chats.unreadChatCount
            if unread > 0 { item.badge = NSMenuItemBadge(count: unread) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: String(localized: "Add Account…"), action: #selector(add), keyEquivalent: "")
        add.target = self
        add.image = NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil)
        menu.addItem(add)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        hub.switchTo(id)
    }

    @objc private func add() {
        hub.addAccount()
    }
}

/// Our picture in a circle, or the generic person, with the unread dot.
enum AccountPicture {
    static func image(url: URL?, size: CGFloat, dot: Bool) -> NSImage {
        let picture = url.flatMap { NSImage(contentsOf: $0) }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            if let picture {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: rect).addClip()
                picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else if let person = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
                ) {
                person.draw(in: rect.insetBy(dx: 1, dy: 1))
            }
            if dot {
                let diameter = size * 0.36
                let spot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: spot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: spot).fill()
            }
            return true
        }
        image.accessibilityDescription = String(localized: "Accounts")
        return image
    }
}
