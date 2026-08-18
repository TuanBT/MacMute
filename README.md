<p align="center">
  <img src="assets/icon.png" width="128" alt="MacMute icon">
</p>

<h1 align="center">MacMute</h1>

<p align="center">
  One shortcut to mute your mic from anywhere on macOS — built for Microsoft Teams.<br>
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

Press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>M</kbd> from any app and your mic goes quiet.
No need to find the Teams window first, and no Teams API — so it keeps working even when
your company disables third-party access.

## Install

1. Download the `.dmg` from the [latest release](https://github.com/TuanBT/MacMute/releases/latest)
   and drag **MacMute** into Applications.
2. **First launch is blocked by macOS.** MacMute has no paid Apple Developer signature, so:
   - **macOS 15 and later** — open MacMute once, let it be blocked, then go to
     **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
   - **macOS 13–14** — right-click the app and choose **Open**.
   - Or from Terminal, on any version: `xattr -cr /Applications/MacMute.app`
3. Grant **System Settings › Privacy & Security › Accessibility** so MacMute can reach the
   Teams mute button.

Without Accessibility permission MacMute still works — it just mutes the input device instead.

## Using it

The menu bar icon always shows the real state:

| Icon | Meaning |
|---|---|
| Thin mic | Mic live, no meeting |
| Filled mic | Mic live, in a Teams meeting |
| Red crossed mic | Muted |

Click the icon to change the shortcut, toggle **Launch at Login**, or quit.

## How it works

Two paths, picked automatically:

- **In a Teams meeting** — MacMute presses the real *Mute mic* button through the macOS
  Accessibility API. Teams performs its own action, so its window updates instantly and
  everyone in the meeting sees the correct state. MacMute reads the button label back, so
  the menu bar icon stays in sync even when you mute by clicking inside Teams.
- **Anywhere else** — MacMute mutes the default input device, which covers Zoom, Google
  Meet, Slack huddles and everything else. Those apps are genuinely muted, but their own
  UI will not show it.

## Updating

The app signature changes on every build, so macOS treats each update as a new app and
asks for Accessibility permission again. Remove the old MacMute entry under
**System Settings › Privacy & Security › Accessibility** and add the new one.

## Requirements

- macOS 13 or later
- Microsoft Teams is optional — without it, the input-device path handles everything

## Build from source

Swift Package Manager, no dependencies. Xcode command line tools are enough.

```bash
git clone https://github.com/TuanBT/MacMute.git
cd MacMute
./build.sh          # builds dist/MacMute.app
```

See [`ReleaseUtils/`](ReleaseUtils/) for the full release pipeline. Pushing a `v*` tag
builds and publishes a release from GitHub Actions.

## License

[MIT](LICENSE)
