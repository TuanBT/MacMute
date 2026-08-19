<p align="center">
  <img src="assets/icon.png" width="128" alt="MacMute icon">
</p>

<h1 align="center">MacMute</h1>

<p align="center">
  One shortcut to mute your mic from anywhere on macOS.<br>
  <a href="https://github.com/TuanBT/MacMute/releases/latest">Download</a>
</p>

<p align="center">
  <a href="https://github.com/TuanBT/MacMute/actions/workflows/ci.yml"><img src="https://github.com/TuanBT/MacMute/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/TuanBT/MacMute/releases/latest"><img src="https://img.shields.io/github/v/release/TuanBT/MacMute" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

<p align="center">
  <img src="assets/menu.png" width="480" alt="MacMute menu in the macOS menu bar">
</p>

Press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>M</kbd> from any app and your mic goes quiet — no need to
find the right window first.

## Why MacMute?

MacMute mutes your microphone at the **device level**, so it works with every app:
**Microsoft Teams, Zoom, Google Meet, Slack, Discord, FaceTime** — anything that captures
audio is covered.

For Microsoft Teams specifically, MacMute also presses the in-app Mute button so other
participants see you as muted, not just silent. This is especially useful since **Microsoft
has retired the local API that third-party apps used to integrate with Teams** — MacMute
uses the Accessibility API as the only remaining way to sync the mute indicator.

## Features

- **Global shortcut from anywhere** — configurable, default <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>M</kbd>
- **Mutes every microphone** — not just the system default, because apps like Teams can pick
  a different input device
- **Teams mute indicator sync** — presses the real Mute button inside the Teams window
  (requires Accessibility permission)
- **Works with all apps** — Zoom, Meet, Slack, Discord, FaceTime, and more
- **Audio feedback** — four sound styles (Click, Soft, Marimba, Chime) or off; falling tone
  for mute, rising for unmute. Hover over each option to preview the sound live
- **Menu bar icon** — two styles to choose from (Coloured Icon or Filled Badge); colour shows mic status at a glance
- **Safe** — restores all microphones on quit, on crash signals, and on next launch
- **Lightweight** — 0% CPU when idle, no polling, about 4 ms from keypress to silence
- **Launch at Login** — start automatically with macOS

## Install

1. Download the `.dmg` from the [latest release](https://github.com/TuanBT/MacMute/releases/latest)
   and drag **MacMute** into Applications.

2. **Remove the quarantine flag** — MacMute is not signed with a paid Apple Developer ID,
   so macOS will block it. Run this once in Terminal:

   ```bash
   xattr -cr /Applications/MacMute.app
   ```

   Alternatively: open MacMute, let it be blocked, then go to
   **System Settings › Privacy & Security** and click **Open Anyway**.

3. On first launch, macOS asks for **Accessibility** permission. Grant it so MacMute can
   press the Mute button inside Teams. If you deny it, muting still works — you just lose
   the visible mute indicator in Teams.

## Menu bar icon

The icon shows the real state of your microphone:

| Icon | Meaning |
|---|---|
| Plain mic | Nothing is listening |
| Green mic | An app has your microphone open |
| Red crossed mic | Muted |

Click the icon for settings:

| Option | Description |
|---|---|
| **Change Shortcut…** | Set any key combination (live modifier preview, reset to default) |
| **Sound** | Click, Soft, Marimba, Chime, or Off — hover to preview |
| **Menu Bar Style** | Coloured Icon or Filled Badge |
| **Launch at Login** | Start with macOS |
| **About MacMute** | Version info and GitHub link |

## Requirements

- macOS 13 or later
- **Accessibility** permission — for Teams mute button sync (muting itself needs no permission)

## Build from source

```bash
git clone https://github.com/TuanBT/MacMute.git
cd MacMute
swift test
./build.sh       # builds dist/MacMute.app
```

## License

[MIT](LICENSE)
