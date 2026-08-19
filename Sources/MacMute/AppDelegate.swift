import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let audio = AudioController()
    private let teamsAPI = TeamsAPI()
    private let teamsAX = TeamsAccessibility()
    private let feedback = Feedback()

    private var shortcut = Settings.shortcut
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        HotKeyManager.shared.installHandler()
        HotKeyManager.shared.onTrigger = { [weak self] in self?.toggleMute() }
        HotKeyManager.shared.register(shortcut)

        // No polling anywhere: CoreAudio reports capture starting and stopping, and
        // Teams pushes its own state down the socket.
        audio.onInputActivityChange = { [weak self] in self?.render() }
        teamsAPI.onChange = { [weak self] in self?.render() }
        teamsAPI.start()

        teamsAX.isEnabled = Settings.accessibilityFallbackEnabled
        installSignalHandlers()
        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        teamsAPI.stop()
        // A HAL mute outlives this process, so leaving one behind would kill the
        // microphone system wide with nothing in the macOS UI to explain it.
        audio.restoreOnExit()
    }

    /// `applicationWillTerminate` never runs for SIGTERM or SIGINT, which is how a
    /// killed or logged-out session used to leave the microphone muted for good.
    private func installSignalHandlers() {
        for value in [SIGTERM, SIGINT, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                self?.audio.restoreOnExit()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Muting

    /// The HAL runs first and synchronously, because it is the only layer that decides
    /// whether the microphone is actually live. Teams is told afterwards and is allowed
    /// to fail: the worst case is that its window shows the wrong indicator, never that
    /// the user believes they are muted while still being heard.
    @objc func toggleMute() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let target = !audio.isMuted
        let t1 = DispatchTime.now().uptimeNanoseconds

        // Play before unmuting and after muting, so the tone always happens while the
        // microphone is still closed and can never be picked up by an open mic.
        if !target { feedback.play(.unmute) }
        let t2 = DispatchTime.now().uptimeNanoseconds
        let applied = audio.setMuted(target)
        let t3 = DispatchTime.now().uptimeNanoseconds
        if target { feedback.play(applied ? .mute : .error) }
        if !applied && !target { feedback.play(.error) }
        let t4 = DispatchTime.now().uptimeNanoseconds

        render()
        let t5 = DispatchTime.now().uptimeNanoseconds
        Timing.log(target: target, marks: [t0, t1, t2, t3, t4, t5])

        teamsAPI.setMuted(target)
        // Only worth walking the accessibility tree when the API is not there to do
        // the same job faster and more reliably.
        if !teamsAPI.isConnected { teamsAX.setMuted(target) }
    }

    // MARK: - Presentation

    private var iconState: StatusIcon.State {
        if audio.isMuted { return .muted }
        return audio.isInputActive ? .live : .idle
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(for: iconState, style: Settings.iconStyle,
                                       description: statusText)
        button.toolTip = "MacMute — \(statusText)"
    }

    private var statusText: String {
        let mic = audio.isMuted ? "Muted"
            : (audio.isInputActive ? "Mic live" : "Mic idle")
        if teamsAPI.state.isInMeeting {
            return "\(mic) · Teams meeting" + (teamsAPI.state.isMuted ? " (Teams muted)" : "")
        }
        return mic
    }

    private var teamsStatusText: String {
        if teamsAPI.isConnected {
            return teamsAPI.state.isInMeeting ? "Teams API: connected, in a meeting"
                                              : "Teams API: connected"
        }
        if teamsAX.isEnabled && TeamsAccessibility.isTrusted {
            return "Teams API: unavailable — using Accessibility"
        }
        return "Teams API: unavailable"
    }

    // MARK: - Menu

    private func populate(_ menu: NSMenu) {
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let teams = NSMenuItem(title: teamsStatusText, action: nil, keyEquivalent: "")
        teams.isEnabled = false
        menu.addItem(teams)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: audio.isMuted ? "Unmute" : "Mute",
                                action: #selector(toggleMute), keyEquivalent: "")
        toggle.target = self
        toggle.keyEquivalent = shortcut.menuKeyEquivalent
        toggle.keyEquivalentModifierMask = shortcut.menuModifierMask
        menu.addItem(toggle)

        let change = NSMenuItem(title: "Change Shortcut…",
                                action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)
        menu.addItem(.separator())

        let sound = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        let off = NSMenuItem(title: "Off", action: #selector(disableSound), keyEquivalent: "")
        off.target = self
        off.state = Settings.soundEnabled ? .off : .on
        soundMenu.addItem(off)
        soundMenu.addItem(.separator())
        for pack in Feedback.Pack.allCases {
            let item = NSMenuItem(title: pack.title, action: #selector(changeSoundPack(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pack.rawValue
            item.state = (Settings.soundEnabled && Settings.soundPack == pack) ? .on : .off
            item.toolTip = pack.detail
            soundMenu.addItem(item)
        }
        sound.submenu = soundMenu
        menu.addItem(sound)

        let style = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for option in StatusIcon.Style.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(changeIconStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = Settings.iconStyle == option ? .on : .off
            item.image = StatusIcon.image(for: .muted, style: option, description: option.title)
            styleMenu.addItem(item)
        }
        style.submenu = styleMenu
        menu.addItem(style)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        // Hidden away unless it is actually needed: on a machine where the Teams API
        // answers, this only adds a permission prompt for no benefit.
        if !teamsAPI.isConnected || Settings.accessibilityFallbackEnabled {
            let fallback = NSMenuItem(title: "Fallback: Press Teams Button (Accessibility)",
                                      action: #selector(toggleAccessibilityFallback),
                                      keyEquivalent: "")
            fallback.target = self
            fallback.state = Settings.accessibilityFallbackEnabled ? .on : .off
            menu.addItem(fallback)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacMute",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    @objc private func disableSound() {
        Settings.soundEnabled = false
    }

    /// Plays the pack as it is chosen — picking a sound you cannot hear first is a
    /// guess, and the whole point is that you recognise it later without looking.
    @objc private func changeSoundPack(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pack = Feedback.Pack(rawValue: raw) else { return }
        Settings.soundEnabled = true
        Settings.soundPack = pack
        feedback.play(.unmute, pack: pack)
    }

    @objc private func changeIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = StatusIcon.Style(rawValue: raw) else { return }
        Settings.iconStyle = style
        render()
    }

    @objc private func toggleLaunchAtLogin() {
        if let message = LaunchAtLogin.set(!LaunchAtLogin.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "Could not update login item"
            alert.informativeText = message
            alert.runModal()
        }
    }

    @objc private func toggleAccessibilityFallback() {
        let enabling = !Settings.accessibilityFallbackEnabled
        Settings.accessibilityFallbackEnabled = enabling
        teamsAX.isEnabled = enabling

        guard enabling, !TeamsAccessibility.isTrusted else { return }
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed for this option"
        alert.informativeText = """
            Muting already works without it — MacMute mutes the input device directly, \
            and where the Teams local API is reachable it also tells Teams, with no \
            permission at all.

            This option is the fallback for machines where that API is blocked: it \
            presses the Mute button inside the Teams window instead, so other people in \
            the meeting still see you as muted. It is slower, and it is only used when \
            the API is unavailable.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }
}
