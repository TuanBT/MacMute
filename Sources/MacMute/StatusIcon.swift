import AppKit

/// Draws the menu bar icon.
///
/// Four states, one glyph, one size. Colour answers "does this matter right now" and
/// the slash answers "what is true":
///
///   - idle: nothing is listening, microphone free
///   - mutedIdle: nothing is listening, and the mute is still on for when something does
///   - live: a microphone is open — this is where speaking reaches other people
///   - muted: something is listening and hearing silence
///
/// The two waiting states drop the colour and keep the slash. Nobody can hear you
/// either way, so a red icon there is an alarm about nothing — half an hour after a
/// meeting it says only that the app is still muted, which is when it is least worth
/// shouting — while the slash is still the fact, and the one thing that explains the
/// silence the next app to open the microphone will get.
///
/// Every state is the same symbol at the same point size, differing only in colour and
/// in the slash, because an icon that changes weight or height as it switches reads as
/// the icon jumping rather than as the microphone changing. That is also why all four
/// are filled: an outline glyph next to a filled one looks like the smaller of the two
/// even when the two measure the same.
enum StatusIcon {

    enum State {
        case idle       // no app is capturing
        case mutedIdle  // no app is capturing, and the microphone is muted
        case live       // a microphone is open
        case muted

        var symbolName: String {
            switch self {
            case .muted, .mutedIdle: return "mic.slash.fill"
            case .live, .idle: return "mic.fill"
            }
        }

        /// nil where the icon is a template and follows the menu bar like any other.
        var colour: NSColor? {
            switch self {
            case .live: return .systemGreen
            case .muted: return .systemRed
            case .idle, .mutedIdle: return nil
            }
        }
    }

    /// One point size for all four, and the size the coloured states have always been
    /// drawn at, so nothing moves for anyone already running MacMute.
    private static let glyphSize: CGFloat = 13
    private static var cache: [State: NSImage] = [:]

    static func image(for state: State, description: String) -> NSImage? {
        if let cached = cache[state] {
            cached.accessibilityDescription = description
            return cached
        }
        guard let image = render(state: state, description: description) else { return nil }
        cache[state] = image
        return image
    }

    private static func render(state: State, description: String) -> NSImage? {
        guard let symbol = symbolImage(state.symbolName, size: glyphSize, weight: .regular)
        else { return nil }
        guard let colour = state.colour else {
            symbol.isTemplate = true
            symbol.accessibilityDescription = description
            return symbol
        }
        let image = recoloured(symbol, colour)
        image.accessibilityDescription = description
        return image
    }

    private static func symbolImage(_ name: String, size: CGFloat,
                                    weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Repaints a symbol on its own canvas, the same size as the symbol, so a coloured
    /// state and a template state occupy exactly the same box. Compositing the colour
    /// straight over the glyph would key off the canvas alpha, which is opaque
    /// everywhere, and flood the whole rectangle.
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
