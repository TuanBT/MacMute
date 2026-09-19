import AppKit

// Before the delegate exists: building it already reads the devices and logs them.
let system = ProcessInfo.processInfo.operatingSystemVersionString
let hotkey = Settings.shortcut.displayString
Log.write("===== MacMute \(ShortcutRecorder.versionString) on macOS \(system), "
          + "shortcut \(hotkey), holdToTalk=\(Settings.holdToTalk)")

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
