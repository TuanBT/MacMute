import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let teams = TeamsController()
    private let audio = AudioController()

    private var shortcut = Settings.shortcut
    private var teamsState: TeamsState = .notRunning
    private var systemMuted = false
    private var pollTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        HotKeyManager.shared.installHandler()
        HotKeyManager.shared.onTrigger = { [weak self] in self?.toggleMute() }
        HotKeyManager.shared.register(shortcut)

        requestAccessibilityIfNeeded()
        refreshState(deep: true)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshState(deep: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        pollTimer?.invalidate()
    }

    // MARK: - Muting

    /// Drives whichever layer owns the mic right now, aiming at an explicit target
    /// state rather than blindly flipping — the two layers can disagree, and a stale
    /// device mute must never leave Teams showing "live" over a silent mic.
    @objc func toggleMute() {
        let shouldMute = !isMuted

        if AXIsProcessTrusted() {
            let current = teams.state(deep: true)
            if current == .live || current == .muted {
                if (current == .muted) != shouldMute {
                    teamsState = teams.toggle() ?? current
                } else {
                    teamsState = current
                }
                // A device mute left over from before the meeting would keep the mic
                // silent while Teams shows you as live. Clear it whenever we go live.
                if !shouldMute && audio.isMuted { audio.setMuted(false) }
                systemMuted = audio.isMuted
                render()
                return
            }
        }

        // No Teams meeting (or no Accessibility): mute the input device instead, which
        // covers Zoom, Meet, Slack and anything else.
        audio.setMuted(shouldMute)
        systemMuted = audio.isMuted
        teamsState = AXIsProcessTrusted() ? teams.state(deep: false) : .idle
        if !AXIsProcessTrusted() {
            // Draw the new state first; the alert is modal and would freeze the icon.
            DispatchQueue.main.async { [weak self] in self?.nagAboutAccessibilityOnce() }
        }
        render()
    }

    private var hasNagged = false

    private func nagAboutAccessibilityOnce() {
        guard !hasNagged else { return }
        hasNagged = true
        showAccessibilityAlert()
    }

    private func refreshState(deep: Bool) {
        teamsState = teams.state(deep: deep)
        systemMuted = audio.isMuted
        render()
    }

    // MARK: - Presentation

    private var isMuted: Bool {
        if systemMuted { return true }
        return teamsState == .muted
    }

    private var inMeeting: Bool {
        teamsState == .muted || teamsState == .live
    }

    private func render() {
        guard let button = statusItem.button else { return }

        let symbol: String
        let tint: NSColor?
        if isMuted {
            symbol = "mic.slash.fill"
            tint = .systemRed
        } else if inMeeting {
            symbol = "mic.fill"
            tint = nil
        } else {
            symbol = "mic"
            tint = nil
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        if let tint {
            image?.isTemplate = false
            let tinted = image?.tinted(with: tint)
            tinted?.accessibilityDescription = statusText
            button.image = tinted
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.toolTip = "MacMute — \(statusText)"
    }

    private var statusText: String {
        // Without Accessibility we cannot see Teams at all, so say that rather than
        // claiming Teams is not running.
        guard AXIsProcessTrusted() else {
            return "Accessibility needed · System mic \(systemMuted ? "muted" : "live")"
        }
        switch teamsState {
        case .muted: return "Teams meeting · Muted"
        case .live: return systemMuted ? "Teams meeting · Muted by system mic"
                                       : "Teams meeting · Live"
        case .idle: return systemMuted ? "No meeting · System mic muted"
                                       : "No meeting · System mic live"
        case .notRunning: return systemMuted ? "Teams not running · System mic muted"
                                             : "Teams not running · System mic live"
        }
    }

    // MARK: - Menu

    private func populate(_ menu: NSMenu) {
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isMuted ? "Unmute" : "Mute",
                                action: #selector(toggleMute), keyEquivalent: "")
        toggle.target = self
        toggle.keyEquivalent = shortcut.menuKeyEquivalent
        toggle.keyEquivalentModifierMask = shortcut.menuModifierMask
        menu.addItem(toggle)

        let change = NSMenuItem(title: "Change Shortcut…",
                                action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let grant = NSMenuItem(title: "⚠︎ Grant Accessibility Access…",
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacMute", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Menu actions

    @objc private func changeShortcut() {
        ShortcutRecorder.present(current: shortcut) { [weak self] new in
            guard let self, let new else { return }
            guard HotKeyManager.shared.register(new) else {
                HotKeyManager.shared.register(self.shortcut)
                let alert = NSAlert()
                alert.messageText = "Shortcut unavailable"
                alert.informativeText = "\(new.displayString) is already claimed by macOS or another app. The previous shortcut is still active."
                alert.runModal()
                return
            }
            self.shortcut = new
            Settings.shortcut = new
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !LaunchAtLogin.isEnabled
        if let message = LaunchAtLogin.set(target) {
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = message
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility permission

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access required"
        alert.informativeText = """
            MacMute is muting the system input device, which works everywhere but leaves \
            the Teams window showing you as unmuted.

            To have Teams itself flip its mute button, open System Settings › Privacy & \
            Security › Accessibility and enable MacMute.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshState(deep: true)
        menu.removeAllItems()
        populate(menu)
    }
}

// MARK: - Small helpers

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }
}

enum Settings {
    private static let key = "shortcut"

    static var shortcut: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .standard }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
