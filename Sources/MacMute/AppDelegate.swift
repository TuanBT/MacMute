import AppKit
import ApplicationServices
import MacMuteCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let audio = AudioController()
    private let teamsAX = TeamsAccessibility()
    private let feedback = Feedback()

    private var shortcut = Settings.shortcut
    private var signalSources: [DispatchSourceSignal] = []
    private var previewTimer: Timer?
    private var previewToneIsUnmute = false

    /// Alive only between a press of the shortcut and whatever ends it, so the app
    /// still has nothing running while you are not touching the keyboard.
    private var hold = HoldGesture()
    private var holdTimer: Timer?

    /// Where the microphone was before a call borrowed it, and nil whenever the state
    /// it is in now is one the user chose for themselves.
    private var borrowedFrom: Bool?
    private var releaseToken = 0

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        HotKeyManager.shared.installHandler()
        HotKeyManager.shared.onTrigger = { [weak self] in self?.shortcutPressed() }
        HotKeyManager.shared.onRelease = { [weak self] in self?.shortcutReleased() }
        HotKeyManager.shared.register(shortcut)

        // No polling anywhere: CoreAudio reports capture starting and stopping, and
        // Teams is only ever asked on the one edge that can have changed its answer.
        audio.onInputActivityChange = { [weak self] in
            guard let self else { return }
            if self.audio.isInputActive { self.feedback.warmUp() } else { self.scheduleRelease() }
            self.render()
        }
        audio.onCaptureStarted = { [weak self] in self?.followTeams() }
        installSignalHandlers()
        observeSessionInterruptions()
        render()
        Timing.note("accessibility trusted: \(TeamsAccessibility.isTrusted)")
        requestAccessibilityOnce()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        stopHoldWatchdog()
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

    /// The press edge of the shortcut. The toggle happens here, at the speed it always
    /// had, and whether it stands is decided when the key comes back up — waiting to
    /// find out would put the hold threshold in front of every mute.
    private func shortcutPressed() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        Timing.note("press  \(modifierReport()) holdToTalk=\(Settings.holdToTalk)")
        guard Settings.holdToTalk else { return toggleMute() }
        let before = audio.isMuted
        apply(!before, since: t0)
        hold.began(stateBefore: before, at: ProcessInfo.processInfo.systemUptime)
        startHoldWatchdog()
    }

    /// The release edge. A tap leaves the toggle standing; a hold hands the microphone
    /// back to the state it was in before the key went down.
    private func shortcutReleased() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = hold.held(at: now)
        guard let outcome = hold.ended(at: now) else {
            Timing.note("release with no press in flight")
            return
        }
        Timing.note(String(format: "release after %.0f ms -> %@",
                           (elapsed ?? 0) * 1000,
                           outcome == .keep ? "tap, toggle stands" : "hold, reverting"))
        stopHoldWatchdog()
        settle(outcome)
    }

    /// Which modifiers are physically down right now.
    ///
    /// The tell for a remapped mouse button: software that synthesises ⌃⌥⌘M posts the
    /// chord and drops it again in the same breath, so the hotkey fires with nothing
    /// actually held down — which is also why the watchdog cannot trust its own reading
    /// on that path.
    private func modifierReport() -> String {
        let down = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var out = ""
        if down.contains(.control) { out += "⌃" }
        if down.contains(.option)  { out += "⌥" }
        if down.contains(.shift)   { out += "⇧" }
        if down.contains(.command) { out += "⌘" }
        return "physical=[" + (out.isEmpty ? "none" : out) + "]"
    }

    @objc func toggleMute() {
        let t0 = DispatchTime.now().uptimeNanoseconds
        // Whatever the microphone was lent for the duration of a call, this is the user
        // taking it back: from here on the state is theirs and outlives the call.
        borrowedFrom = nil
        // The menu names an absolute state, so a press still in flight has nothing left
        // to say about it.
        hold.cancel()
        stopHoldWatchdog()
        apply(!audio.isMuted, since: t0)
    }

    private func settle(_ outcome: HoldGesture.Outcome) {
        guard case .revert(let previous) = outcome else {
            // A tap that stands is the user choosing this state. A hold that reverts
            // puts back the state that was already there, borrowed or not, so it says
            // nothing about who owns it.
            borrowedFrom = nil
            return
        }
        apply(previous, since: DispatchTime.now().uptimeNanoseconds)
    }

    /// The HAL runs first and synchronously, because it is the only layer that decides
    /// whether the microphone is actually live. Teams is told afterwards and is allowed
    /// to fail: the worst case is that its window shows the wrong indicator, never that
    /// the user believes they are muted while still being heard.
    ///
    /// Teams is told on the hold edges too, and has to be: its Mute button is a second,
    /// app-level mute, so a hold that opened the microphone without pressing it would
    /// leave Teams still muted and the user talking to nobody.
    ///
    /// `t0` comes from the caller so the stopwatch still covers the state read that
    /// chose `target`.
    private func apply(_ target: Bool, since t0: UInt64) {
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

    // MARK: - Following Teams

    /// Takes Teams' own mute state as the truth, once, when a call starts.
    ///
    /// Teams decides that state for itself when it joins — its settings, the meeting's,
    /// and nothing at all about the mute this app was left holding when the last call
    /// ended. Whichever of the two is right, they have to agree: while they do not, the
    /// microphone is either dead behind a Teams that shows you live, or live behind a
    /// mute you think you still have, and the first press of the shortcut goes to
    /// moving the half that was already correct.
    ///
    /// Teams is believed here and only here. It is the side other participants can see,
    /// and a call starting is the one moment where nothing the user did with the
    /// shortcut is being overruled — any press cancels a read still in flight.
    private func followTeams() {
        releaseToken += 1   // a call starting settles nothing that was owed to the last one
        teamsAX.readMuted { [weak self] teamsMuted in
            guard let self, teamsMuted != self.audio.isMuted else { return }
            Timing.note("call started with Teams \(teamsMuted ? "muted" : "live"), following it")
            // What the microphone was doing before the call is kept, because this state
            // is on loan from Teams and has to be given back when the call ends.
            if self.borrowedFrom == nil { self.borrowedFrom = self.audio.isMuted }
            // Teams is already where it says it is, so it is not told anything back.
            self.audio.setMuted(teamsMuted)
            self.render()
        }
    }

    /// Gives back the state the call borrowed, once the call is over.
    ///
    /// Teams' own mute ends with the call; a HAL mute does not. Adopting one at the
    /// start of a call and then keeping it leaves the microphone dead for every other
    /// app afterwards, with nothing left in Teams to explain the red icon — a mute
    /// nobody chose and only this app knows how to undo.
    ///
    /// Only ever a state the user did not choose: a press of the shortcut, in either
    /// direction, hands ownership to them and there is nothing left here to give back.
    private func scheduleRelease() {
        guard borrowedFrom != nil else { return }
        releaseToken += 1
        let token = releaseToken
        // Capture stopping is not proof a meeting ended. Teams stops one device and
        // starts another when it switches, and for a moment in between nothing is
        // capturing at all; releasing on that would open the microphone mid-call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, token == self.releaseToken else { return }
            guard !self.audio.isInputActive, let previous = self.borrowedFrom else { return }
            self.borrowedFrom = nil
            guard previous != self.audio.isMuted else { return }
            Timing.note("call over, giving the microphone back to \(previous ? "muted" : "live")")
            self.audio.setMuted(previous)
            self.render()
        }
    }

    // MARK: - Hold watchdog

    /// Runs only while the key is down, which is why the app can carry a timer at all
    /// without giving up its idle cost.
    ///
    /// It exists because `kEventHotKeyReleased` is not a promise: releasing the
    /// modifiers before the key swallows it, and a hold whose release never arrives
    /// would leave the microphone in the borrowed state — the exact accident that
    /// hold-to-talk is supposed to make impossible. Watching the modifiers is the
    /// tighter of the two nets, since nobody is still holding ⌃⌥⌘M with Control up, and
    /// the ceiling in `HoldGesture` catches what it cannot see: a shortcut bound to a
    /// bare function key has no modifiers to watch.
    private func startHoldWatchdog() {
        stopHoldWatchdog()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkHold()
        }
    }

    private func stopHoldWatchdog() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func checkHold() {
        guard hold.isHolding else { return stopHoldWatchdog() }

        let required = shortcut.menuModifierMask
        let down = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !required.isEmpty, !down.isSuperset(of: required) {
            Timing.note("hold: modifiers up without a release event")
            endHold()
            return
        }

        if let outcome = hold.expired(at: ProcessInfo.processInfo.systemUptime) {
            Timing.note("hold: hit the \(Int(HoldGesture.maxHold))s ceiling")
            stopHoldWatchdog()
            settle(outcome)
        }
    }

    /// Gives up on a press macOS is never going to report the end of, and returns the
    /// microphone to where it was.
    private func endHold() {
        guard let outcome = hold.abandon() else { return }
        stopHoldWatchdog()
        settle(outcome)
    }

    /// Sleep, a locked screen and a switched session all take the keyboard away without
    /// a release event. None of them may leave the microphone borrowed.
    private func observeSessionInterruptions() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.endHold()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.endHold() }
    }

    // MARK: - Presentation

    private var iconState: StatusIcon.State {
        guard audio.isInputActive else { return audio.isMuted ? .mutedIdle : .idle }
        return audio.isMuted ? .muted : .live
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let status = statusText
        button.image = StatusIcon.image(for: iconState, description: status)
        button.toolTip = "MacMute — \(status)"
    }

    /// The icon drops the colour once nothing is listening; the words do not drop the
    /// mute, so the menu and the tooltip still say it in as many letters.
    private var statusText: String {
        guard audio.isInputActive else { return audio.isMuted ? "Muted, nothing listening" : "Mic idle" }
        return audio.isMuted ? "Muted" : "Mic live"
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
        soundMenu.delegate = self
        menu.addItem(sound)

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

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About MacMute",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem(title: "Quit MacMute",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Menu actions

    /// The escape hatch, called from the settings panel. Unlike Unmute this does not
    /// consult a baseline, because the case it exists for is the one where the baseline
    /// is the thing that is wrong.
    private func forceUnmute() {
        borrowedFrom = nil
        hold.cancel()
        stopHoldWatchdog()
        audio.forceUnmuteEverything()
        teamsAX.setMuted(false)
        render()
    }

    private func setHoldToTalk(_ enabled: Bool) {
        Settings.holdToTalk = enabled
        // Switching it off mid-press leaves a hold nothing will ever end.
        if !enabled { endHold() }
    }

    @objc private func openSettings() {
        // Rebinding unregisters the key that is being held, so its release is gone.
        endHold()
        let actions = ShortcutRecorder.Actions(
            setHoldToTalk: { [weak self] enabled in self?.setHoldToTalk(enabled) },
            forceUnmute: { [weak self] in self?.forceUnmute() })
        ShortcutRecorder.present(current: shortcut, holdToTalk: Settings.holdToTalk,
                                 actions: actions) { [weak self] new in
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

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MacMute"
        alert.informativeText = """
            Version \(ShortcutRecorder.versionString)

            One shortcut to mute your mic from anywhere on macOS.
            """
        alert.addButton(withTitle: "GitHub")
        alert.addButton(withTitle: "OK")

        if let icon = NSImage(named: "AppIcon") ?? NSImage(named: NSImage.applicationIconName) {
            alert.icon = icon
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/TuanBT/MacMute")!)
        }
    }

    // MARK: - Sound preview

    private func startPreview(for pack: Feedback.Pack) {
        stopPreview()
        // Play the first tone immediately
        previewToneIsUnmute = false
        feedback.play(.mute, pack: pack)

        // Then alternate mute/unmute every 1.2 seconds
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.previewToneIsUnmute.toggle()
            self.feedback.play(self.previewToneIsUnmute ? .unmute : .mute, pack: pack)
        }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
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
            MacMute needs Accessibility to press the Mute button inside Teams \
            so others see you as muted, not just silent.

            After granting access, please restart MacMute.
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
        // Only rebuild the main status item menu, not submenus
        if menu == statusItem.menu {
            menu.removeAllItems()
            populate(menu)
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // Only handle sound submenu highlights
        guard menu != statusItem.menu else {
            // Main menu: stop any running preview when moving away from Sound submenu
            stopPreview()
            return
        }

        // This is a submenu — check if the highlighted item is a sound pack
        if let raw = item?.representedObject as? String,
           let pack = Feedback.Pack(rawValue: raw) {
            startPreview(for: pack)
        } else {
            stopPreview()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        stopPreview()
    }
}
