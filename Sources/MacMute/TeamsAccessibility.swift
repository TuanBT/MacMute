import AppKit
import ApplicationServices

/// Presses the Teams mute button through the Accessibility API.
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
/// Unlike the version this replaces, it never runs on the main thread, never blocks a
/// keypress, and never drives the menu bar icon. The icon follows the HAL, which is
/// the layer that actually decides whether the microphone is live.
///
/// Measured against Teams 26213: locating the button costs about 35 ms, the press
/// itself 0.1 ms, and the label still reads "mute mic" immediately afterwards, turning
/// into "unmute mic" only around 100 ms later. Reading it back straight after the press
/// — which the version this replaces did — therefore always returned the previous
/// value, and that is what used to leave the icon showing the opposite of reality.
final class TeamsAccessibility {

    private static let bundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
    private static let strongLabels: Set<String> = ["mute mic", "unmute mic"]
    private static let rejectWords = ["all", "everyone", "others", "participant",
                                      "chat", "conversation", "notification"]

    /// The real control is described "Mute mic". The Settings window carries checkboxes
    /// like "Keyboard shortcut to unmute — Press and hold Option + Spacebar…", which
    /// contain the word and would otherwise be a plausible fallback. Nothing that long
    /// is a toolbar button.
    private static let maxFallbackLabel = 30

    private let queue = DispatchQueue(label: "com.tuanbt.macmute.ax", qos: .userInitiated)

    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var cachedButton: AXUIElement?
    private var cooldownUntil = Date.distantPast

    /// Bumped by anything that makes a pending read stale. Queue confined, like every
    /// other field here.
    private var readEpoch = 0

    /// True once the user has granted Accessibility. Never prompts.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Best effort, fire and forget. Returns immediately.
    func setMuted(_ muted: Bool) {
        guard Self.isTrusted else {
            Log.write("teams: no Accessibility permission, button not touched")
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            // A press is the user saying where they want to be. A read still in flight
            // from a call that just started must not land on top of it a second later
            // and undo it.
            self.readEpoch += 1
            self.press(target: muted)
        }
    }

    /// Reads what Teams itself shows, so the app can follow Teams instead of only ever
    /// pushing at it.
    ///
    /// A call starting is the one moment the two are guaranteed to disagree: Teams
    /// joins with whatever mute state its own settings and the meeting decide, knowing
    /// nothing about the mute this app was still holding from the last call. Left
    /// disagreeing, the next press of the shortcut spends itself moving the half that
    /// was already where the user wanted it — which is why it took two.
    ///
    /// The meeting toolbar is not there the instant capture starts, so this retries
    /// within `window` and simply never answers when no mute button ever appears: no
    /// call in progress, Teams not running, or no Accessibility permission. The
    /// completion runs on the main queue, at most once.
    func readMuted(within window: TimeInterval = 8, _ completion: @escaping (Bool) -> Void) {
        guard Self.isTrusted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.readEpoch += 1
            self.attemptRead(self.readEpoch, until: Date().addingTimeInterval(window),
                             after: 0.4, completion)
        }
    }

    private func attemptRead(_ epoch: Int, until deadline: Date, after delay: TimeInterval,
                             _ completion: @escaping (Bool) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, epoch == self.readEpoch else { return }
            // A call starting is exactly what a cooldown left over from the last failed
            // scan would hide, and the one moment a scan is certainly worth paying for.
            self.cooldownUntil = .distantPast
            if let button = self.resolveButton(), let label = self.label(of: button) {
                // Same reading as the press path: the label names the action, so
                // "unmute mic" means Teams is muted right now.
                let muted = label.contains("unmute")
                Log.write("teams: call start read \"\(label)\" -> Teams is \(muted ? "muted" : "live")")
                DispatchQueue.main.async { completion(muted) }
                return
            }
            guard Date() < deadline else {
                Log.write("teams: call start read found no mute button, giving up")
                return
            }
            self.attemptRead(epoch, until: deadline, after: 1.5, completion)
        }
    }

    // MARK: - Work, entirely off the main thread

    private func press(target muted: Bool) {
        guard let button = resolveButton() else {
            Log.write("teams: no mute button found (no call, or Teams not running)")
            return
        }
        guard let label = label(of: button) else {
            Log.write("teams: mute button has no label")
            return
        }

        // The label names the action the button performs, so "unmute mic" means Teams
        // is currently muted. Only press when Teams disagrees with where we are going.
        let teamsIsMuted = label.contains("unmute")
        guard teamsIsMuted != muted else {
            Log.write("teams: shows \"\(label)\", already \(muted ? "muted" : "live"), not pressed")
            return
        }

        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else {
            Log.write("teams: press on \"\(label)\" FAILED (AXError \(result.rawValue))")
            cachedButton = nil
            return
        }
        Log.write("teams: pressed \"\(label)\"")
        // The label only flips about 100 ms after the press, so the reading that says
        // whether Teams actually followed has to wait for it.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let after = self.label(of: button)
            let followed = after.map { $0.contains("unmute") == muted } ?? false
            Log.write("teams: after press shows \"\(after ?? "nil")\""
                      + (followed ? "" : " ⚠︎ Teams did NOT follow"))
        }
    }

    private func resolveButton() -> AXUIElement? {
        if let cached = cachedButton, label(of: cached) != nil { return cached }
        cachedButton = nil
        if Date() < cooldownUntil { return nil }

        let found = scan()
        cachedButton = found
        if let found {
            Log.write("teams: found mute button \"\(label(of: found) ?? "nil")\" in pid \(appPID)")
        }
        if found == nil { cooldownUntil = Date().addingTimeInterval(3) }
        return found
    }

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

    private func label(of element: AXUIElement) -> String? {
        let parts = [string(element, kAXTitleAttribute as String),
                     string(element, kAXDescriptionAttribute as String)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
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
