import AppKit

/// Small modal panel that captures the next key combination the user presses.
final class ShortcutRecorder {
    private static var shared: ShortcutRecorder?

    private var window: NSWindow?
    private var monitor: Any?
    private var completion: ((Shortcut?) -> Void)?
    private let promptLabel = NSTextField(labelWithString: "")

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (build \(build))"
    }

    static func present(current: Shortcut, completion: @escaping (Shortcut?) -> Void) {
        shared?.close(with: nil)
        let recorder = ShortcutRecorder()
        shared = recorder
        recorder.show(current: current, completion: completion)
    }

    private func show(current: Shortcut, completion: @escaping (Shortcut?) -> Void) {
        self.completion = completion

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 176),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "Change Shortcut"
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

        // The panel is the only window MacMute ever shows, so it carries the version.
        let version = NSTextField(labelWithString: "MacMute \(ShortcutRecorder.versionString)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        version.alignment = .center

        let stack = NSStackView(views: [title, promptLabel, hint, version])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        window = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil  // swallow the key so it never reaches anything else
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            close(with: nil)
            return
        }
        guard let shortcut = Shortcut.from(event: event) else {
            promptLabel.stringValue = "Needs a modifier"
            return
        }
        promptLabel.stringValue = shortcut.displayString
        // Brief pause so the user sees what was captured before the panel disappears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.close(with: shortcut)
        }
    }

    private func close(with shortcut: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window = nil
        let callback = completion
        completion = nil
        ShortcutRecorder.shared = nil
        callback?(shortcut)
    }
}
