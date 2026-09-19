import AppKit

// Before the delegate exists: building it already reads the devices and logs them.
Log.write("===== MacMute \(ShortcutRecorder.versionString) on macOS "
          + "\(ProcessInfo.processInfo.operatingSystemVersionString), "
          + "shortcut \(Settings.shortcut.displayString), holdToTalk=\(Settings.holdToTalk)")

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
