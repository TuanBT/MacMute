import AppKit

/// Draws the menu bar icon.
///
/// Three states, with colour carrying the meaning at a glance:
///   - nothing is listening: plain template glyph, follows the menu bar like any other
///     icon and stays out of the way
///   - a microphone is live: green, because this is the state where speaking reaches
///     other people
///   - muted: red
///
/// The idle state is always a template glyph. Only the two coloured states have a
/// style, because those are the ones that have to be read in a hurry and taste differs
/// on how loudly they should say it.
enum StatusIcon {

    enum State {
        case idle       // no app is capturing
        case live       // a microphone is open
        case muted
    }

    enum Style: String, CaseIterable {
        /// No block at all: just the glyph, tinted. Closest to macOS convention, and
        /// the default — a filled block reads as a system alert rather than an app.
        case glyph
        /// A filled block the full height of the icon. Loudest, and heaviest.
        case badge

        var title: String {
            switch self {
            case .badge: return "Filled Badge"
            case .glyph: return "Coloured Icon"
            }
        }
    }

    private static let canvas = NSSize(width: 22, height: 20)
    private static var cache: [String: NSImage] = [:]

    static func image(for state: State, style: Style, description: String) -> NSImage? {
        let key = "\(state)-\(style.rawValue)"
        if let cached = cache[key] {
            cached.accessibilityDescription = description
            return cached
        }
        guard let image = render(state: state, style: style, description: description)
        else { return nil }
        cache[key] = image
        return image
    }

    private static func render(state: State, style: Style, description: String) -> NSImage? {
        guard state != .idle else {
            let image = NSImage(systemSymbolName: "mic", accessibilityDescription: description)
            image?.isTemplate = true
            return image
        }

        let symbol = state == .muted ? "mic.slash.fill" : "mic.fill"
        let colour: NSColor = state == .muted ? .systemRed : .systemGreen

        switch style {
        case .badge:
            return badge(symbol: symbol, colour: colour, description: description,
                         box: NSSize(width: 19, height: 17), corner: 4.5,
                         glyphSize: 11, weight: .semibold)

        case .glyph:
            guard let raw = symbolImage(state == .muted ? "mic.slash.fill" : "mic.fill",
                                        size: 13, weight: .regular) else { return nil }
            let image = recoloured(raw, colour)
            image.accessibilityDescription = description
            return image
        }
    }

    private static func badge(symbol: String, colour: NSColor, description: String,
                              box: NSSize, corner: CGFloat,
                              glyphSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard let raw = symbolImage(symbol, size: glyphSize, weight: weight) else { return nil }
        let white = recoloured(raw, .white)

        let image = NSImage(size: canvas, flipped: false) { rect in
            colour.setFill()
            let block = NSRect(x: (rect.width - box.width) / 2,
                               y: (rect.height - box.height) / 2,
                               width: box.width, height: box.height)
            NSBezierPath(roundedRect: block, xRadius: corner, yRadius: corner).fill()

            let size = white.size
            white.draw(in: NSRect(x: (rect.width - size.width) / 2,
                                  y: (rect.height - size.height) / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }

    private static func symbolImage(_ name: String, size: CGFloat,
                                    weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Repaints a symbol on its own transparent canvas. Compositing colour straight
    /// onto the badge would key off the badge's alpha, which is opaque everywhere, and
    /// flood the whole block.
    private static func recoloured(_ symbol: NSImage, _ colour: NSColor) -> NSImage {
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            colour.set()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }
}
