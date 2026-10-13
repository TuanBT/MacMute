import AppKit
import ApplicationServices
import MacMuteCore

/// Reads and presses the Teams mute button through the Accessibility API.
///
/// Microsoft retired the local API that used to do this without any permission — Teams
/// 26198 still answered on port 8124, 26213 no longer opens it — so this is the only
/// remaining way to make Teams itself show the mute, and therefore the only way other
/// people in a meeting see it rather than merely hearing silence. It always runs.
///
/// Without the permission it does nothing and muting is unaffected: the microphone is
/// silenced by the audio device either way, which is the part that must never depend
/// on a permission being granted.
///
/// It never runs on the main thread, never blocks a keypress, and never drives the
/// menu bar icon. The icon follows the HAL, which is the layer that actually decides
/// whether the microphone is live.
///
/// It works both ways. A press of the shortcut presses the button, and presses it again
/// if the label shows Teams did not follow. And for as long as anything has a
/// microphone open the button is read twice a second, so a mute changed inside Teams —
/// its own button, its own shortcut, a headset Teams listens to — reaches the app,
/// instead of leaving Teams showing you live over a muted microphone. What each reading
/// means is decided in `TeamsSync`; this type only talks to Teams.
///
/// Measured against Teams 26213: locating the button costs about 35 ms, the press
/// itself 0.1 ms, and the label still reads "mute mic" immediately afterwards, turning
/// into "unmute mic" only around 100 ms later. Reading it back straight after the press
/// — which an earlier version did — therefore always returned the previous value, and
/// that is what used to leave the icon showing the opposite of reality.
final class TeamsAccessibility {

    enum Reading { case muted, live, unknown }

    private static let bundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
    private static let strongLabels: Set<String> = ["mute mic", "unmute mic"]
    private static let rejectWords = ["all", "everyone", "others", "participant",
                                      "chat", "conversation", "notification"]

    /// The real control is described "Mute mic". The Settings window carries checkboxes
    /// like "Keyboard shortcut to unmute — Press and hold Option + Spacebar…", which
    /// contain the word and would otherwise be a plausible fallback. Nothing that long
    /// is a toolbar button.
    private static let maxFallbackLabel = 30

    /// How often the button is read while a microphone is open. From the cached element
    /// that is two attribute reads; the scan that finds the element again runs far less
    /// often, at the pace `TeamsSync.scanGap` sets.
    private static let watchInterval: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.tuanbt.macmute.ax", qos: .userInitiated)

    // Everything below is queue confined.
    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var cachedButton: AXUIElement?
    private var lastFailedScan = -TimeInterval.infinity
    private var sync = TeamsSync()
    /// Bumped by every start and stop, so a tick left over from a watch that has ended
    /// stops itself.
    private var watch = 0
    /// The latest press the main thread has told us about. It goes out with every
    /// report, so a reading taken before a newer press is recognised there and dropped.
    private var serial = 0
    private var reportedMissing = false

    /// Teams showed something it was not asked to: a change made inside Teams, or the
    /// first reading of a call. Main queue.
    var onChange: ((_ teamsMuted: Bool, _ serial: Int, _ first: Bool) -> Void)?

    /// Teams would not follow the shortcut, however often it was pressed. Main queue.
    var onGaveUp: ((_ target: Bool) -> Void)?

    /// True once the user has granted Accessibility. Never prompts.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Moves Teams to where the user just sent the microphone. Fire and forget: returns
    /// at once, and keeps at it in the background until Teams shows it or gives up.
    func setMuted(_ muted: Bool, serial: Int) {
        guard Self.isTrusted else {
            Log.write("teams: no Accessibility permission, button not touched")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.serial = serial
            self.sync.ask(muted, serial: serial, at: self.now)
            self.reportedMissing = false
            self.deliver()
        }
    }

    /// Something opened a microphone. Reads the button until `stopWatching`.
    func startWatching() {
        guard Self.isTrusted else { return }
        queue.async { [weak self] in
            guard let self, !self.sync.isWatching else { return }
            self.sync.begin(at: self.now)
            self.watch += 1
            // A call starting is exactly what a scan that failed a moment ago would hide.
            self.lastFailedScan = -.infinity
            let watch = self.watch
            // The meeting toolbar is not there the instant capture starts.
            self.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick(watch) }
        }
    }

    /// Nothing has had a microphone open for a while: the call is over.
    func stopWatching() {
        queue.async { [weak self] in
            guard let self, self.sync.isWatching else { return }
            self.sync.end()
            self.watch += 1
        }
    }

    /// Reads Teams for a decision about a microphone whose mute just changed underneath
    /// the app. Tries at each delay in turn, since the label flips about 100 ms after
    /// Teams does and the button may not be on screen yet; `.unknown` when it never
    /// turns up. The completion runs on the main queue.
    ///
    /// Never answers while a press of ours is on its way to Teams: that press is what
    /// Teams is about to show, whatever it shows this instant, and it may well be what
    /// moved the device. A press still waiting for a button to appear is another
    /// matter — it is delivered if the button is there now, and otherwise this answers
    /// `.unknown` like any other look that found nothing.
    func check(after delays: [TimeInterval], _ completion: @escaping (Reading) -> Void) {
        guard Self.isTrusted else {
            DispatchQueue.main.async { completion(.unknown) }
            return
        }
        queue.async { [weak self] in self?.attemptCheck(delays[...], completion) }
    }

    // MARK: - Work, entirely off the main thread

    /// Moves Teams toward the standing request, or leaves the request standing for the
    /// watch to deliver once the button can be found.
    private func deliver() {
        guard let request = sync.request else { return }
        let wait = sync.wait(at: now)
        guard wait == 0 else {
            // A press is still settling and its label has not flipped. Reading it now is
            // how two presses 8 ms apart used to undo each other.
            schedule(after: wait, for: request.serial)
            return
        }
        guard let found = currentButton(scanGap: sync.scanGap(at: now)) else {
            if !reportedMissing {
                reportedMissing = true
                Log.write("teams: no mute button found (no call, or Teams not running)")
            }
            return
        }
        let (button, label) = found
        // The label names the action the button performs, so "unmute mic" means Teams
        // is currently muted.
        let teamsMuted = label.contains("unmute")
        let waited = sync.followsDevice
        let step = sync.read(teamsMuted, at: now)
        if sync.followsDevice && !waited {
            Log.write("teams: Teams follows the microphone's own mute this call, "
                      + "waiting for it before pressing from now on")
        }
        switch step {
        case .settled(let pressed):
            if pressed {
                Log.write("teams: after press shows \"\(label)\"")
            } else if waited {
                Log.write("teams: shows \"\(label)\", followed the microphone by itself, not pressed")
            } else {
                Log.write("teams: shows \"\(label)\", already \(Self.state(teamsMuted)), not pressed")
            }
        case .gaveUp(let target):
            Log.write("teams: ⚠︎ still shows \"\(label)\" after \(TeamsSync.maxPresses) presses, giving up")
            DispatchQueue.main.async { [weak self] in self?.onGaveUp?(target) }
        case .press:
            if request.presses > 0 {
                Log.write("teams: shows \"\(label)\" ⚠︎ Teams did NOT follow, pressing again")
            } else if waited {
                Log.write("teams: shows \"\(label)\", did not follow the microphone this time, pressing")
            }
            press(button, label, serial: request.serial)
        case .nothing, .changed:
            break
        }
    }

    private func press(_ button: AXUIElement, _ label: String, serial: Int) {
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        sync.pressed(at: now)
        if result == .success {
            Log.write("teams: pressed \"\(label)\"")
        } else {
            Log.write("teams: press on \"\(label)\" FAILED (AXError \(result.rawValue))")
            cachedButton = nil
        }
        // Whether Teams followed is read once the label has had time to flip, and the
        // button is pressed again if it did not.
        schedule(after: TeamsSync.settle, for: serial)
    }

    private func schedule(after delay: TimeInterval, for serial: Int) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.sync.request?.serial == serial else { return }
            self.deliver()
        }
    }

    private func tick(_ watch: Int) {
        guard watch == self.watch, sync.isWatching else { return }
        defer {
            queue.asyncAfter(deadline: .now() + Self.watchInterval) { [weak self] in self?.tick(watch) }
        }
        // A press waiting to be delivered has the button until it lands or gives up.
        guard sync.request == nil else { return deliver() }
        guard sync.wait(at: now) == 0,
              let found = currentButton(scanGap: sync.scanGap(at: now)) else { return }
        let label = found.1
        guard case .changed(let muted, let first) = sync.read(label.contains("unmute"), at: now)
        else { return }
        Log.write(first ? "teams: first reading \"\(label)\" -> Teams is \(Self.state(muted))"
                        : "teams: now shows \"\(label)\", changed inside Teams")
        let serial = self.serial
        DispatchQueue.main.async { [weak self] in self?.onChange?(muted, serial, first) }
    }

    private func attemptCheck(_ delays: ArraySlice<TimeInterval>,
                              _ completion: @escaping (Reading) -> Void) {
        guard let delay = delays.first else {
            Log.write("teams: checked, no mute button to read")
            DispatchQueue.main.async { completion(.unknown) }
            return
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let request = self.sync.request {
                guard request.presses == 0 else { return }
                if self.currentButton(scanGap: 0) != nil { return self.deliver() }
            } else if self.sync.wait(at: self.now) == 0, let found = self.currentButton(scanGap: 0) {
                let teamsMuted = found.1.contains("unmute")
                // Kept as the latest reading, so the watch does not report it twice.
                _ = self.sync.read(teamsMuted, at: self.now)
                Log.write("teams: checked, shows \"\(found.1)\"")
                DispatchQueue.main.async { completion(teamsMuted ? .muted : .live) }
                return
            }
            self.attemptCheck(delays.dropFirst(), completion)
        }
    }

    /// The button and what it says: from the cached element while it still answers,
    /// otherwise from a scan, as long as the last scan that came back empty is at least
    /// `scanGap` old.
    private func currentButton(scanGap: TimeInterval) -> (AXUIElement, String)? {
        if let cached = cachedButton {
            if let text = label(of: cached) { return (cached, text) }
            cachedButton = nil
        }
        guard now - lastFailedScan >= scanGap else { return nil }
        guard let found = scan(), let text = label(of: found) else {
            lastFailedScan = now
            return nil
        }
        cachedButton = found
        Log.write("teams: found mute button \"\(text)\" in pid \(appPID)")
        return (found, text)
    }

    private static func state(_ muted: Bool) -> String { muted ? "muted" : "live" }

    private func teamsApp() -> AXUIElement? {
        let running = Self.bundleIDs
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .first
        guard let running else {
            appElement = nil
            appPID = 0
            return nil
        }
        if running.processIdentifier != appPID || appElement == nil {
            appPID = running.processIdentifier
            let element = AXUIElementCreateApplication(appPID)
            // Chromium-backed views only build a full AX tree once a client asks, and
            // Teams needs both switches: with AXManualAccessibility alone, build 26213
            // exposes 20 nodes per window and no mute button at all. With
            // AXEnhancedUserInterface as well it exposes about 380 and the button
            // appears as an AXButton described "Mute mic".
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            // Without this a busy Teams can hang each call for the six second default.
            AXUIElementSetMessagingTimeout(element, 0.25)
            appElement = element
            cachedButton = nil
        }
        return appElement
    }

    /// Walks every window rather than guessing from the title. The previous version
    /// ranked windows by English title prefixes, so a Teams running in any other
    /// language fell through to the wrong window and the press silently did nothing.
    ///
    /// Two passes, because a weaker match in one window must never win over the real
    /// control in another: the Settings window contains checkboxes mentioning mute, and
    /// window order is not guaranteed to put the meeting first.
    private func scan() -> AXUIElement? {
        guard let app = teamsApp() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        var fallback: AXUIElement?
        for window in windows {
            var budget = 3000
            if let button = search(window, &budget, 0, strongOnly: true) { return button }
            if fallback == nil {
                var budget = 3000
                fallback = search(window, &budget, 0, strongOnly: false)
            }
        }
        return fallback
    }

    private func search(_ element: AXUIElement, _ budget: inout Int, _ depth: Int,
                        strongOnly: Bool) -> AXUIElement? {
        if budget <= 0 || depth > 45 { return nil }
        budget -= 1

        var fallback: AXUIElement?
        let role = string(element, kAXRoleAttribute as String) ?? ""
        if role == "AXButton" || role == "AXCheckBox" || role == "AXToggle" {
            if let text = label(of: element) {
                if Self.strongLabels.contains(text) { return element }
                // Only a button, and only a short label. Checkboxes describing a
                // preference are neither.
                if !strongOnly, role == "AXButton", text.count <= Self.maxFallbackLabel,
                   text.contains("mute"),
                   !Self.rejectWords.contains(where: { text.contains($0) }) {
                    fallback = element
                }
            }
        }

        for child in children(of: element) {
            if let hit = search(child, &budget, depth + 1, strongOnly: strongOnly) { return hit }
        }
        return fallback
    }

    // MARK: - AX helpers

    /// Title and description, the same text once. Teams gives the button its label as
    /// both, and read twice it came out "mute mic mute mic", which no strong label
    /// matches: the button was only ever found by the fallback pass, after every window
    /// had already been walked once for nothing. The watch scans far more often than
    /// presses ever did, so that walk is worth not paying.
    private func label(of element: AXUIElement) -> String? {
        var parts: [String] = []
        for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
            guard let text = string(element, attribute), !text.isEmpty,
                  !parts.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame })
            else { continue }
            parts.append(text)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ").lowercased()
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
