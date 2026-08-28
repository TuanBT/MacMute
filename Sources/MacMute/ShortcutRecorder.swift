import AppKit

/// The settings panel: captures the next key combination the user presses, and carries
/// everything that is decided once and then left alone.
///
/// The menu is what you open mid-meeting to mute, so what stays in it is the mute, the
/// things you genuinely change between calls, and the way out. What lives here instead
/// is set-and-forget: the shortcut itself, whether the shortcut can be held, and the
/// escape hatch for a microphone that has gone silent with nothing in macOS to explain
/// it — worth keeping, worth being able to find, and not worth a line above Quit.
final class ShortcutRecorder {

    /// What the panel is allowed to do to the running app. Closures rather than a
    /// delegate: there are three of them and they are all one line.
    struct Actions {
        var setHoldToTalk: (Bool) -> Void
        var forceUnmute: () -> Void
    }

    private static var shared: ShortcutRecorder?

    private var window: NSWindow?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var completion: ((Shortcut?) -> Void)?
    private var actions: Actions?
    private let promptLabel = NSTextField(labelWithString: "")
    private let forceButton = NSButton(title: "Force Unmute All Devices", target: nil, action: nil)
    private var currentShortcut: Shortcut?
    private var originalColor: NSColor = .labelColor

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (build \(build))"
    }

    static func present(current: Shortcut, holdToTalk: Bool, actions: Actions,
                        completion: @escaping (Shortcut?) -> Void) {
        shared?.close(with: nil)
        let recorder = ShortcutRecorder()
        shared = recorder
        recorder.show(current: current, holdToTalk: holdToTalk, actions: actions,
                      completion: completion)
    }

    private func show(current: Shortcut, holdToTalk: Bool, actions: Actions,
                      completion: @escaping (Shortcut?) -> Void) {
        self.completion = completion
        self.actions = actions
        self.currentShortcut = current

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 380),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "MacMute Settings"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        let title = NSTextField(labelWithString: "Press the new shortcut")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center

        promptLabel.stringValue = "Current: \(current.displayString)"
        promptLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        promptLabel.alignment = .center

        let hint = NSTextField(labelWithString: "Esc to cancel · at least one modifier, or a function key")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let resetButton = NSButton(title: "Reset to Default (\(Shortcut.standard.displayString))",
                                   target: self, action: #selector(resetToDefault))
        resetButton.bezelStyle = .recessed
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 11)

        let holdCheckbox = NSButton(checkboxWithTitle: "Hold to Talk", target: self,
                                    action: #selector(toggleHoldToTalk(_:)))
        holdCheckbox.state = holdToTalk ? .on : .off

        let holdHint = NSTextField(wrappingLabelWithString:
            "Tap the shortcut to toggle, as usual. Hold it and the microphone only "
            + "changes while the key is down: push-to-talk while muted, push-to-mute "
            + "while live.")
        holdHint.font = .systemFont(ofSize: 11)
        holdHint.textColor = .secondaryLabelColor
        holdHint.alignment = .center
        holdHint.preferredMaxLayoutWidth = 320

        forceButton.target = self
        forceButton.action = #selector(forceUnmuteEverything)
        forceButton.bezelStyle = .rounded

        let forceHint = NSTextField(wrappingLabelWithString:
            "Clears the mute on every input device, whatever put it there. For a "
            + "microphone that is silent with nothing in macOS to explain it.")
        forceHint.font = .systemFont(ofSize: 11)
        forceHint.textColor = .secondaryLabelColor
        forceHint.alignment = .center
        forceHint.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [title, promptLabel, hint, resetButton,
                                        rule(), holdCheckbox, holdHint,
                                        rule(), forceButton, forceHint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(20, after: resetButton)
        stack.setCustomSpacing(16, after: stack.views[4])
        stack.setCustomSpacing(6, after: holdCheckbox)
        stack.setCustomSpacing(20, after: holdHint)
        stack.setCustomSpacing(16, after: stack.views[7])
        stack.setCustomSpacing(6, after: forceButton)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.views[4].widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            stack.views[7].widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        panel.contentView = content
        window = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil  // swallow the key so it never reaches anything else
        }

        // Live modifier preview: show which modifiers are held in real time
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Shows modifiers in real time as they are held down, e.g. "⌃⌥…"
    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option)  { parts += "⌥" }
        if flags.contains(.shift)   { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }

        if parts.isEmpty {
            // All modifiers released — show current shortcut again
            if let current = currentShortcut {
                promptLabel.stringValue = "Current: \(current.displayString)"
            }
            promptLabel.textColor = .labelColor
        } else {
            promptLabel.stringValue = "\(parts)…"
            promptLabel.textColor = .labelColor
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            close(with: nil)
            return
        }
        guard let shortcut = Shortcut.from(event: event) else {
            // Flash red and shake to signal the error
            flashError("Needs a modifier")
            return
        }
        promptLabel.textColor = .systemGreen
        promptLabel.stringValue = shortcut.displayString
        // Brief pause so the user sees what was captured before the panel disappears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.close(with: shortcut)
        }
    }

    /// Shakes the prompt label and flashes it red briefly.
    private func flashError(_ message: String) {
        promptLabel.stringValue = message
        promptLabel.textColor = .systemRed

        // Shake animation
        if let layer = promptLabel.layer ?? promptLabel.superview?.layer {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.timingFunction = CAMediaTimingFunction(name: .linear)
            shake.duration = 0.4
            shake.values = [0, -8, 8, -6, 6, -3, 3, 0]
            layer.add(shake, forKey: "shake")
        }

        // Restore color after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.promptLabel.textColor = .labelColor
            if let current = self.currentShortcut {
                self.promptLabel.stringValue = "Current: \(current.displayString)"
            }
        }
    }

    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func toggleHoldToTalk(_ sender: NSButton) {
        actions?.setHoldToTalk(sender.state == .on)
    }

    /// Says so afterwards. The whole point of the button is a microphone that is silent
    /// for no visible reason, and a click that changes nothing on screen is
    /// indistinguishable from a click that did not work.
    @objc private func forceUnmuteEverything() {
        actions?.forceUnmute()
        forceButton.title = "Every Device Unmuted"
        forceButton.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.forceButton.title = "Force Unmute All Devices"
            self?.forceButton.isEnabled = true
        }
    }

    @objc private func resetToDefault() {
        let standard = Shortcut.standard
        promptLabel.textColor = .systemGreen
        promptLabel.stringValue = standard.displayString
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.close(with: standard)
        }
    }

    private func close(with shortcut: Shortcut?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        window?.orderOut(nil)
        window = nil
        actions = nil
        let callback = completion
        completion = nil
        ShortcutRecorder.shared = nil
        callback?(shortcut)
    }
}
