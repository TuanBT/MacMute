import AppKit
import Carbon.HIToolbox

/// A global hotkey definition stored in Carbon terms (that is what RegisterEventHotKey wants).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// Ctrl+Option+Command+M
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_M),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey))

    /// Builds a shortcut from a key event. Returns nil for combinations we refuse to bind.
    static func from(event: NSEvent) -> Shortcut? {
        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }

        let code = UInt32(event.keyCode)
        // Function keys are usable on their own; anything else needs a modifier
        // so we never swallow plain typing.
        if mods == 0 && !functionKeyNames.keys.contains(code) { return nil }
        if code == UInt32(kVK_Escape) { return nil }
        return Shortcut(keyCode: code, modifiers: mods)
    }

    /// Menu-style rendering, e.g. "⌃⌥⌘M".
    var displayString: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out + Shortcut.keyName(keyCode)
    }

    /// How AppKit wants the same combination, for showing it next to a menu item.
    /// Function keys fall back to an empty equivalent — the global hotkey still works,
    /// the menu simply does not draw it.
    var menuKeyEquivalent: String {
        let name = Shortcut.keyName(keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        return flags
    }

    private static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1",   UInt32(kVK_F2): "F2",   UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",   UInt32(kVK_F5): "F5",   UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",   UInt32(kVK_F8): "F8",   UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space",       UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",             UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",   UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",             UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",      UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
    ]

    /// Resolves a virtual key code to the character it produces on the current layout.
    static func keyName(_ code: UInt32) -> String {
        if let n = functionKeyNames[code] { return n }
        if let n = namedKeys[code] { return n }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(code)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout,
                                  UInt16(code),
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  chars.count,
                                  &length,
                                  &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Owns the single global hotkey registration.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    /// The key coming back up. Carbon posts this as well as the press, which is what
    /// makes hold-to-talk possible without a CGEventTap and the extra permission one
    /// would cost. It is not guaranteed to arrive — releasing the modifiers before the
    /// key can swallow it — so nothing may depend on it alone.
    var onRelease: (() -> Void)?

    private init() {}

    func installHandler() {
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                manager.onRelease?()
            } else {
                manager.onTrigger?()
            }
            return noErr
        }
        specs.withUnsafeBufferPointer { buffer in
            _ = InstallEventHandler(GetApplicationEventTarget(), callback, buffer.count,
                                    buffer.baseAddress,
                                    Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        }
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D4D5445), id: 1)  // 'MMTE'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
