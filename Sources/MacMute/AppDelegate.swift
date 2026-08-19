import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let audio = AudioController()
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
        audio.onInputActivityChange = { [weak self] in
            guard let self else { return }
            if self.audio.isInputActive { self.feedback.warmUp() }
            self.render()
        }
        installSignalHandlers()
        render()
        Timing.note("accessibility trusted: \(TeamsAccessibility.isTrusted)")
        requestAccessibilityOnce()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
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
        teamsAX.setMuted(target)
        let t3 = DispatchTime.now().uptimeNanoseconds

        if target { feedback.play(applied ? .mute : .error) }
        if !applied && !target { feedback.play(.error) }
        let t4 = DispatchTime.now().uptimeNanoseconds

        render()
        let t5 = DispatchTime.now().uptimeNanoseconds
        Timing.log(target: target, marks: [t0, t1, t2, t3, t4, t5])
    }

    // MARK: - Presentation

    private var iconState: StatusIcon.State {
        if audio.isMuted { return .muted }
        return audio.isInputActive ? .live : .idle
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let status = statusText
        button.image = StatusIcon.image(for: iconState, style: Settings.iconStyle,
                                        description: status)
        button.toolTip = "MacMute — \(status)"
    }

    private var statusText: String {
        let mic = audio.isMuted ? "Muted"
            : (audio.isInputActive ? "Mic live" : "Mic idle")
        return mic
    }

    private var teamsStatusText: String {
        TeamsAccessibility.isTrusted ? "Teams button: synced"
                                     : "Teams button: needs Accessibility"
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

        // Only worth a menu entry while it is missing; once granted there is nothing
        // to decide.
        if !TeamsAccessibility.isTrusted {
            let grant = NSMenuItem(title: "⚠︎ Grant Accessibility Access…",
                                   action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
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

    /// Asked once, at launch, using the system's own prompt. Pressing the Teams
    /// button is not optional any more, so hiding the request behind a menu toggle
    /// would just mean the feature silently never worked.
    private func requestAccessibilityOnce() {
        guard !TeamsAccessibility.isTrusted, !Settings.hasAskedForAccessibility else { return }
        Settings.hasAskedForAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func grantAccessibility() {
        presentAccessibilityAlert()
    }

    private func presentAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed for this option"
        alert.informativeText = """
            Muting already works without it — MacMute mutes the input device directly.

            This option additionally presses the Mute button inside the Teams window, \
            so other people in the meeting see you as muted rather than just silent. \
            Microsoft retired the local API that used to do this without any \
            permission, so Accessibility is now the only way.
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
