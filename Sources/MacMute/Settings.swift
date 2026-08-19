import Foundation

enum Settings {
    private static let shortcutKey = "shortcut"
    private static let soundKey = "soundEnabled"
    private static let askedKey = "askedForAccessibility"
    private static let iconStyleKey = "iconStyle"
    private static let soundPackKey = "soundPack"

    static var shortcut: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: shortcutKey),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .standard }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: shortcutKey)
        }
    }

    /// On by default: the confirmation tone is the whole point of the feedback work.
    static var soundEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }

    static var iconStyle: StatusIcon.Style {
        get {
            guard let raw = UserDefaults.standard.string(forKey: iconStyleKey),
                  let value = StatusIcon.Style(rawValue: raw) else { return .glyph }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: iconStyleKey) }
    }

    static var soundPack: Feedback.Pack {
        get {
            guard let raw = UserDefaults.standard.string(forKey: soundPackKey),
                  let value = Feedback.Pack(rawValue: raw) else { return .click }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: soundPackKey) }
    }

    /// So the permission is asked for once, at the moment it would first have made a
    /// difference, rather than in a dialog on first launch.
    static var hasAskedForAccessibility: Bool {
        get { UserDefaults.standard.bool(forKey: askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }
}
