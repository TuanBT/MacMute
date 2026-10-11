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

    /// Counts the presses Teams has been told about. A reading of Teams taken before the
    /// latest one is about a state the user has already moved on from, and is dropped.
    private var teamsSerial = 0

    /// Whether a stretch of capture is under way, and since when. The first seconds of
    /// a call are Teams deciding how it starts, which is followed without a sound.
    private var inCall = false
    private var callBegan = -TimeInterval.infinity

    /// When the mute tone last said that a mute was kept against something opening the
    /// microphone, so a device that keeps doing it does not turn into a drum roll.
    private var lastNotice = -TimeInterval.infinity

    /// When a microphone muted from outside was last opened, so something that keeps
    /// muting it again is left alone rather than fought every half second.
    private var recentOpens: [TimeInterval] = []
    private var gaveUpOpening = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        HotKeyManager.shared.installHandler()
        HotKeyManager.shared.onTrigger = { [weak self] in self?.shortcutPressed() }
        HotKeyManager.shared.onRelease = { [weak self] in self?.shortcutReleased() }
        HotKeyManager.shared.register(shortcut)

        // Nothing is polled while no microphone is open: CoreAudio reports capture
        // starting and stopping, and the Teams button is only read while it is open.
        audio.onInputActivityChange = { [weak self] in
            guard let self else { return }
            if self.audio.isInputActive { self.feedback.warmUp() } else { self.scheduleCallEnd() }
            self.render()
        }
        audio.onCaptureStarted = { [weak self] in self?.captureStarted() }
        // The only moment the icon cannot be trusted, so it is the moment to be loud.
        audio.onMuteLost = { [weak self] in self?.warnMuteLost() }
        audio.onReopenedWhileMuted = { [weak self] in self?.reopenedWhileMuted() }
        audio.onSilencedWhileLive = { [weak self] in self?.silencedWhileLive() }
        teamsAX.onChange = { [weak self] teamsMuted, serial, first in
            self?.teamsChanged(teamsMuted, serial: serial, first: first)
        }
        teamsAX.onGaveUp = { [weak self] target in self?.teamsWouldNotFollow(target) }
        installSignalHandlers()
        observeSessionInterruptions()
        render()
        Timing.note("accessibility trusted: \(TeamsAccessibility.isTrusted)")
        requestAccessibilityOnce()
        // Launched into a call already under way, which nothing will report starting.
        if audio.isInputActive { captureStarted() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        stopHoldWatchdog()
        // A HAL mute outlives this process, so leaving one behind would kill the
        // microphone system wide with nothing in the macOS UI to explain it.
        audio.restoreOnExit()
        Log.write("quit")
        Log.flush()
    }

    /// `applicationWillTerminate` never runs for SIGTERM or SIGINT, which is how a
    /// killed or logged-out session used to leave the microphone muted for good.
    private func installSignalHandlers() {
        for value in [SIGTERM, SIGINT, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                Log.write("signal \(value)")
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
    /// whether the microphone is actually live. Teams is told afterwards, in the
    /// background, and pressed again until its label shows it followed. It is still
    /// allowed to fail — an organiser's hard mute will not budge — and then the error
    /// tone says the two disagree, rather than leaving the user to find out from the
    /// silence.
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

        Log.write("apply -> \(target ? "MUTE" : "UNMUTE")")
        let applied = audio.setMuted(target)
        tellTeams(target)
        let t3 = DispatchTime.now().uptimeNanoseconds
        if !applied { Log.write("⚠︎ no device accepted the \(target ? "mute" : "unmute")") }

        if target { feedback.play(applied ? .mute : .error) }
        if !applied && !target { feedback.play(.error) }
        let t4 = DispatchTime.now().uptimeNanoseconds

        render()
        let t5 = DispatchTime.now().uptimeNanoseconds
        Timing.log(target: target, marks: [t0, t1, t2, t3, t4, t5])
        // Late enough for the deferred devices and Teams' own reaction to have landed.
        audio.logSnapshot("after \(target ? "mute" : "unmute")", after: 0.5)
    }

    /// A device came back live and could not be closed. Worse than never muting: the
    /// icon says you cannot be heard. The error tone says otherwise, and the alert says
    /// what to do about it, since only the user can pull the headset or leave the call.
    private func warnMuteLost() {
        feedback.play(.error)
        render()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Microphone may be live"
        alert.informativeText = """
            An input device lost its mute and MacMute could not close it again. \
            Mute in Teams directly, or disconnect the device, until this is resolved.
            """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Following Teams

    /// Tells Teams where the user just sent the microphone. Every reading of Teams taken
    /// before this carries an older number, and is dropped when it arrives.
    private func tellTeams(_ muted: Bool) {
        teamsSerial += 1
        teamsAX.setMuted(muted, serial: teamsSerial)
    }

    /// Something opened a microphone, which is what a call starting looks like from
    /// here. Teams is watched from now until nothing has captured for a moment.
    private func captureStarted() {
        releaseToken += 1   // a call starting settles nothing that was owed to the last one
        guard !inCall else { return }
        inCall = true
        callBegan = ProcessInfo.processInfo.systemUptime
        teamsAX.startWatching()
    }

    /// Teams showed something it was not asked to: the first reading of a call, or a
    /// mute changed inside Teams itself.
    private func teamsChanged(_ teamsMuted: Bool, serial: Int, first: Bool) {
        // Read before the latest press, so about a state the user has moved on from.
        guard serial == teamsSerial else { return }
        let state = teamsMuted ? "muted" : "live"
        follow(teamsMuted, first ? "call started with Teams \(state)" : "Teams went \(state) inside Teams")
    }

    /// Moves the microphone to where Teams is, which is the side other participants see.
    ///
    /// Teams used to be believed once per call, when it started, and pushed at
    /// everywhere else, so a mute changed inside Teams left the two apart for the rest
    /// of the call — and the half the user watches during a call is Teams. The log has
    /// it plainly: twice inside two seconds something took the mute off the microphone
    /// in use, the app put it straight back both times, and ten seconds later the
    /// shortcut found Teams had been showing "live" all along.
    ///
    /// Whatever Teams lends lasts for the call, the same as the state a call starts
    /// with: Teams' own mute ends when the call does and a HAL mute does not, so it is
    /// handed back when the call is over. A press of the shortcut takes ownership, as
    /// it always has.
    private func follow(_ teamsMuted: Bool, _ reason: String) {
        // A key held down is the user steering the microphone this very moment.
        guard !hold.isHolding else { return }
        guard teamsMuted != audio.isMuted else {
            // Both say live, so the microphone the call is using had better be live too.
            if !teamsMuted { openSilenced() }
            return
        }
        Timing.note("\(reason), following it")
        if borrowedFrom == nil { borrowedFrom = audio.isMuted }
        // The first seconds of a call are Teams deciding how it starts, followed quietly
        // as they always were. After that it is someone acting inside Teams, and the
        // microphone moving sounds the way the shortcut would make it sound.
        let audible = ProcessInfo.processInfo.systemUptime - callBegan > 3
        if audible && !teamsMuted { feedback.play(.unmute) }
        // Teams is already where it says it is, so it is not told anything back.
        audio.setMuted(teamsMuted)
        if audible && teamsMuted { feedback.play(.mute) }
        render()
        audio.logSnapshot("after following Teams", after: 0.5)
    }

    /// A microphone in use lost the mute we put on it, and the mute is already back on.
    ///
    /// Most often that was Teams: it writes its own mute into the device, so unmuting
    /// inside Teams takes ours off, and putting it back without asking left Teams
    /// showing you live over a dead microphone — the report this whole section answers.
    /// So Teams is asked. Live means that was you, and the microphone follows. Muted
    /// means Teams agrees with the mute that went back, which is what a driver resetting
    /// as a call opens looks like. No answer — no Teams, no Accessibility, another app
    /// entirely — keeps the mute, because the app says muted, but says so out loud.
    ///
    /// The mute goes back before the question is asked, so the microphone is never open
    /// while the answer is on its way. Unmuting inside Teams costs a quarter of a second
    /// of speech for it.
    ///
    /// A call that is still joining gets longer to answer. Teams writes the device as it
    /// joins, which makes that the commonest moment of all for this, and its toolbar is
    /// often not on screen yet — five seconds after capture began, in one log. Asked too
    /// early, every such call would play the tone for a mute Teams agrees with.
    private func reopenedWhileMuted() {
        let serial = teamsSerial
        // Two statements, not a ternary: two array literals either side of `?:` took the
        // type checker over twelve minutes.
        var delays: [TimeInterval] = [0.25, 0.5, 1.0]
        if ProcessInfo.processInfo.systemUptime - callBegan < 10 { delays += [1.5, 1.5, 1.5, 2.0] }
        teamsAX.check(after: delays) { [weak self] reading in
            guard let self, serial == self.teamsSerial, self.audio.isMuted else { return }
            switch reading {
            case .live: self.follow(false, "microphone opened from outside while Teams shows live")
            case .muted: break
            case .unknown: self.noticeMuteKept()
            }
        }
    }

    /// Whatever opened the microphone was most likely the user, unmuting somewhere this
    /// app cannot read, and they are still not being heard. The mute tone says so.
    private func noticeMuteKept() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastNotice > 5 else { return }
        lastNotice = now
        Timing.note("microphone opened from outside and muted again, no Teams to ask, telling the user")
        feedback.play(.mute)
    }

    /// A microphone in use went quiet while the app says live: muted from inside Teams,
    /// which writes that into the device as well, or left muted by something else on
    /// the device a call has just moved to. Teams says which.
    private func silencedWhileLive() {
        let serial = teamsSerial
        teamsAX.check(after: [0.6, 1]) { [weak self] reading in
            guard let self, serial == self.teamsSerial, !self.audio.isMuted else { return }
            switch reading {
            case .muted: self.follow(true, "microphone muted from outside while Teams shows muted")
            case .live: self.openSilenced()
            case .unknown: break
            }
        }
    }

    private func openSilenced() {
        let now = ProcessInfo.processInfo.systemUptime
        recentOpens = recentOpens.filter { now - $0 < 30 }
        guard recentOpens.count < 3 else {
            if !gaveUpOpening { Timing.note("something keeps muting the microphone in use, leaving it be") }
            gaveUpOpening = true
            return
        }
        gaveUpOpening = false
        guard !audio.openCapturingDevices().isEmpty else { return }
        recentOpens.append(now)
        render()
        audio.logSnapshot("after opening a microphone muted from outside", after: 0.5)
    }

    /// Teams ignored the button however often it was pressed — an organiser's hard mute
    /// does exactly that. The microphone did what was asked and Teams shows otherwise,
    /// and only the user can say which of the two they meant.
    private func teamsWouldNotFollow(_ target: Bool) {
        Timing.note("Teams would not \(target ? "mute" : "unmute"), it no longer matches the microphone")
        feedback.play(.error)
    }

    /// Ends the call once nothing has captured for a moment: Teams stops being watched,
    /// and the state the call borrowed is given back.
    ///
    /// Teams' own mute ends with the call; a HAL mute does not. Adopting one during a
    /// call and then keeping it leaves the microphone dead for every other app
    /// afterwards, with nothing left in Teams to explain the red icon — a mute nobody
    /// chose and only this app knows how to undo.
    ///
    /// Only ever a state the user did not choose: a press of the shortcut, in either
    /// direction, hands ownership to them and there is nothing left here to give back.
    private func scheduleCallEnd() {
        releaseToken += 1
        let token = releaseToken
        // Capture stopping is not proof a meeting ended. Teams stops one device and
        // starts another when it switches, and for a moment in between nothing is
        // capturing at all; ending the call on that would open the microphone mid-call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, token == self.releaseToken, !self.audio.isInputActive else { return }
            if self.inCall {
                self.inCall = false
                self.teamsAX.stopWatching()
            }
            guard let previous = self.borrowedFrom else { return }
            self.borrowedFrom = nil
            guard previous != self.audio.isMuted else { return }
            Timing.note("call over, giving the microphone back to \(previous ? "muted" : "live")")
            self.audio.setMuted(previous)
            self.render()
            self.audio.logSnapshot("after call ended", after: 0.5)
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
                Log.write("session: \(name.rawValue)")
                self?.endHold()
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                              queue: .main) { [weak self] _ in
            // Devices come back from sleep renegotiated, and not always wearing the mute
            // they went to sleep with.
            Log.write("session: woke")
            self?.audio.logSnapshot("wake", after: 2)
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
        tellTeams(false)
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
            forceUnmute: { [weak self] in self?.forceUnmute() },
            showLog: { [weak self] in self?.showLog() })
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

    /// Takes a fresh reading first, so the file shows the state as it is now and not
    /// only as it was at the last keypress.
    private func showLog() {
        audio.logSnapshot("log opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Log.flush()
            NSWorkspace.shared.activateFileViewerSelecting([Log.file])
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
