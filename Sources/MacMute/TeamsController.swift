import AppKit
import ApplicationServices

enum TeamsState {
    case notRunning     // Teams is not launched
    case idle           // Teams is running but no meeting window with a mic button
    case live           // in a meeting, mic open
    case muted          // in a meeting, mic muted
}

/// Drives the Microsoft Teams mute button through the Accessibility API.
///
/// Teams v2 is a native shell around MSWebView2. The meeting toolbar lives inside the
/// web view, which does expose an accessibility tree, so the mute control is reachable
/// as a plain AXButton labelled "Mute mic" / "Unmute mic". Pressing it is what makes
/// Teams update its own UI instantly — muting the audio device does not.
final class TeamsController {
    private let bundleID = "com.microsoft.teams2"

    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var cachedButton: AXUIElement?
    private var scanCooldownUntil = Date.distantPast

    /// Window titles we know belong to the main navigation tabs, never to a meeting.
    /// Skipping them keeps the idle poll from walking the 700+ node Calendar tree.
    private static let tabPrefixes = [
        "chat |", "calendar |", "activity |", "teams |", "calls |", "files |",
        "apps |", "help |", "communities |", "settings", "more |", "search",
    ]

    private static let strongLabels: Set<String> = ["mute mic", "unmute mic"]
    private static let rejectWords = ["all", "everyone", "others", "participant",
                                      "chat", "conversation", "notification"]

    // MARK: - Public API

    private var isTeamsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Current state. `deep` allows walking windows whose title does not look like a
    /// meeting — worth the extra milliseconds on a keypress, too slow for a 1s poll.
    func state(deep: Bool) -> TeamsState {
        guard isTeamsRunning else {
            cachedButton = nil
            return .notRunning
        }
        guard let label = currentLabel(deep: deep) else { return .idle }
        return label.contains("unmute") ? .muted : .live
    }

    /// Presses the mute button. Returns the state Teams landed in, or nil if there was
    /// no button to press (caller should fall back to muting the audio device).
    func toggle() -> TeamsState? {
        guard let button = resolveButton(deep: true) else { return nil }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            cachedButton = nil
            return nil
        }
        // Teams flips the label synchronously; read it back so the menu bar icon is
        // driven by Teams' own truth rather than by a guess.
        if let label = label(of: button) {
            return label.contains("unmute") ? .muted : .live
        }
        return nil
    }

    // MARK: - Button resolution

    private func currentLabel(deep: Bool) -> String? {
        guard let button = resolveButton(deep: deep) else { return nil }
        return label(of: button)
    }

    private func resolveButton(deep: Bool) -> AXUIElement? {
        // A cached element stays valid across presses as long as Teams has not rebuilt
        // that part of the DOM, so the common path costs one attribute read.
        if let cached = cachedButton, label(of: cached) != nil { return cached }
        cachedButton = nil

        if !deep && Date() < scanCooldownUntil { return nil }

        let found = scan(deep: deep)
        cachedButton = found
        if found == nil { scanCooldownUntil = Date().addingTimeInterval(3) }
        return found
    }

    private func teamsApp() -> AXUIElement? {
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            appElement = nil
            appPID = 0
            return nil
        }
        if running.processIdentifier != appPID || appElement == nil {
            appPID = running.processIdentifier
            let element = AXUIElementCreateApplication(appPID)
            // Chromium-based views only build a full AX tree once a client asks for it.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            appElement = element
            cachedButton = nil
        }
        return appElement
    }

    private func scan(deep: Bool) -> AXUIElement? {
        guard let app = teamsApp() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        // Rank 0: title mentions a meeting. Rank 1: unknown window. Rank 2: a known tab.
        let ranked = windows.map { window -> (AXUIElement, Int) in
            let title = (string(window, kAXTitleAttribute as String) ?? "").lowercased()
            if title.contains("meeting") || title.contains("call") || title.contains("meet") {
                return (window, 0)
            }
            if Self.tabPrefixes.contains(where: { title.hasPrefix($0) }) { return (window, 2) }
            return (window, 1)
        }.sorted { $0.1 < $1.1 }

        for (window, rank) in ranked {
            if rank == 2 { continue }
            if rank == 1 && !deep { continue }
            var budget = deep ? 4000 : 1200
            if let button = search(window, &budget, 0) { return button }
        }
        return nil
    }

    /// Depth-first walk that stops as soon as it finds an exact "mute mic" button.
    private func search(_ element: AXUIElement, _ budget: inout Int, _ depth: Int) -> AXUIElement? {
        if budget <= 0 || depth > 45 { return nil }
        budget -= 1

        var fallback: AXUIElement?
        let role = string(element, kAXRoleAttribute as String) ?? ""
        if role == "AXButton" || role == "AXCheckBox" || role == "AXToggle" {
            if let text = label(of: element) {
                if Self.strongLabels.contains(text) { return element }
                if text.contains("mute"), !Self.rejectWords.contains(where: { text.contains($0) }) {
                    fallback = element
                }
            }
        }

        for child in children(of: element) {
            if let hit = search(child, &budget, depth + 1) { return hit }
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
