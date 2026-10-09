import AppKit
import ZapFastDesign

// MARK: - Messages arriving

/// A message that arrives while the reader is at the bottom no longer pops
/// in: the chat slides up to make room for it, as in Telegram, and the
/// message rises with it. One we just sent flies there from the composer's
/// field, where its text was typed; one from someone else (or from our
/// phone) fades in as it rises.
///
/// All of it is Core Animation on layers already drawn: the table is moved
/// back down by what it scrolled and springs up, so nothing is laid out
/// again frame by frame.
extension TimelineController {
    /// How long after a send here our own message counts as that send.
    static let sentHereWindow: TimeInterval = 4

    #if DEBUG
    /// `ZAPFAST_SLOW_ARRIVAL=<factor>` slows the arrival down, to look at.
    static let arrivalSlowdown = ProcessInfo.processInfo.environment["ZAPFAST_SLOW_ARRIVAL"].flatMap(Double.init) ?? 1
    #else
    static let arrivalSlowdown = 1.0
    #endif

    /// The rows `rows` were added at the bottom, and the timeline scrolled
    /// `shift` points to show them.
    func animateArrival(rows: Range<Int>, shift: CGFloat) {
        guard shift > 0, shift < clip.bounds.height, rows.count <= 4, let window = tableView.window,
              window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let tableLayer = tableView.layer else { return }
        let slow = Self.arrivalSlowdown

        // The rows above slide up into their new place.
        let slide = CASpringAnimation(keyPath: "transform.translation.y")
        slide.fromValue = Self.downward * shift
        slide.toValue = 0
        slide.isAdditive = true
        slide.mass = 1
        slide.stiffness = 320
        slide.damping = 34
        slide.duration = slide.settlingDuration
        slide.speed = Float(1 / slow)
        // No key: one more message while the last still slides adds its
        // own slide on top, rather than cutting the first one short.
        tableLayer.add(slide, forKey: nil)

        let sentHere = model?.lastSentHere.map { Date().timeIntervalSince($0) < Self.sentHereWindow } ?? false
        for row in rows {
            guard items.indices.contains(row), let message = items[row].message,
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BubbleCell,
                  let layout = cell.bubbleLayout else { continue }
            if message.fromMe, sentHere {
                flyFromComposer(cell, layout: layout)
            } else {
                cell.animateArrival(rising: 10, slowdown: slow)
            }
        }
    }

    /// From the composer's field to its place: across from where the
    /// field's text starts, and down to the field's line.
    private func flyFromComposer(_ cell: BubbleCell, layout: BubbleLayout) {
        let bubble = layout.bubbleFrame(rowWidth: cell.bounds.width)
        let textX = bubble.minX + (layout.body?.rect.minX ?? Metrics.m)
        // The field's text starts after the + button and the field's padding.
        let fieldTextX = Metrics.m + Self.composerButton + Metrics.s + Metrics.m
        let dx = fieldTextX - textX
        // Before the scroll the new row sat right on top of the composer;
        // the field's line is about halfway down it.
        let bottom = clip.contentInsets.bottom
        let dy = max(0, bottom / 2 - bubble.height / 2)
        cell.animateFlight(from: CGPoint(x: dx, y: Self.downward * dy), slowdown: Self.arrivalSlowdown)
    }

    /// The composer's round buttons.
    static let composerButton: CGFloat = 36

    /// The sign of a downward move in the table's layer: AppKit flips the
    /// geometry of a flipped view's layer, so y grows down there.
    static let downward: CGFloat = 1
}

extension BubbleCell {
    static let arrivalKeys = ["arrivalFade", "arrivalRise", "flightX", "flightY", "flightFade"]

    /// A reused cell shows another message: its arrival does not carry over.
    func stopArrival() {
        for key in Self.arrivalKeys { layer?.removeAnimation(forKey: key) }
    }

    /// Fades in while rising `rising` points more than the rows around it.
    func animateArrival(rising: CGFloat, slowdown: Double) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22 * slowdown
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = TimelineController.downward * rising
        rise.toValue = 0
        rise.isAdditive = true
        rise.stiffness = 360
        rise.damping = 34
        rise.duration = rise.settlingDuration
        rise.speed = Float(1 / slowdown)
        layer.add(fade, forKey: Self.arrivalKeys[0])
        layer.add(rise, forKey: Self.arrivalKeys[1])
    }

    /// Flies in from `offset` (where the composer's text was), settling with
    /// a little give, as a sent message does in Telegram.
    func animateFlight(from offset: CGPoint, slowdown: Double) {
        guard let layer else { return }
        for (path, value) in [("transform.translation.x", offset.x), ("transform.translation.y", offset.y)] {
            let fly = CASpringAnimation(keyPath: path)
            fly.fromValue = value
            fly.toValue = 0
            fly.isAdditive = true
            fly.mass = 1
            fly.stiffness = 300
            fly.damping = 31
            fly.duration = fly.settlingDuration
            fly.speed = Float(1 / slowdown)
            layer.add(fly, forKey: path == "transform.translation.x" ? Self.arrivalKeys[2] : Self.arrivalKeys[3])
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = 0.16 * slowdown
        fade.fillMode = .backwards
        layer.add(fade, forKey: Self.arrivalKeys[4])
    }
}
