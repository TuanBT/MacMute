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
No need to find the Teams window first, and **no permissions to grant** — muting happens
at the audio device, which is the only layer that can actually guarantee silence.

## Install

1. Download the `.dmg` from the [latest release](https://github.com/TuanBT/MacMute/releases/latest)
   and drag **MacMute** into Applications.
2. **First launch is blocked by macOS.** MacMute has no paid Apple Developer signature, so:
   - **macOS 15 and later** — open MacMute once, let it be blocked, then go to
     **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
   - **macOS 13–14** — right-click the app and choose **Open**.
   - Or from Terminal, on any version: `xattr -cr /Applications/MacMute.app`

That is the whole setup. MacMute asks for no system permissions.

## Using it

The menu bar icon shows what the microphone is really doing:

| Icon | Meaning |
|---|---|
| Plain mic | Nothing is listening |
| Green mic | An app has your microphone open |
| Red crossed mic | Muted |

Green means *whatever you say right now reaches other people* — it follows the same
signal as the orange dot macOS puts in the menu bar, so it covers Teams, Zoom, Meet and
Slack alike. Every toggle also plays a short confirmation tone, so you never have to
look at the menu bar to know the shortcut landed.

Click the icon to change the shortcut, turn the sound off, toggle **Launch at Login**,
or quit.

## How it works

Three layers, in the order they run on a keypress:

1. **The audio device — always.** MacMute sets `kAudioDevicePropertyMute` on *every*
   input device, not just the current default, because Teams picks its microphone
   independently of the macOS default and asking which one it chose costs more than
   muting all of them (measured: 10 ms against 1.5 ms). This needs no permission, and
   it is the layer the menu bar icon believes.

   Where a device has no real mute, MacMute zeroes its input volume instead, falling
   back to the AudioHardwareService virtual main volume for devices that expose no
   writable volume channel — and keeps it at zero, because Teams raises input gain when
   it joins a meeting and would otherwise quietly reopen the microphone.

   Every write is confirmed by reading the value back. A device reporting success
   proves nothing: the virtual *Microsoft Teams Audio* device accepts both a mute and a
   volume write and then discards them.

2. **The Teams local API — when it is available.** Teams exposes a WebSocket on
   `127.0.0.1:8124`. MacMute holds it open, so toggling mute is one small JSON message
   and Teams registers it properly, which is what makes other people in the meeting see
   you as muted. Teams also pushes its state back, so the icon stays correct even when
   you click mute inside Teams — no polling anywhere.

   The first toggle in a meeting raises a pairing prompt in Teams. Approve it once and
   the token is stored; later launches connect silently.

3. **Accessibility — only if you turn it on.** Some machines have the local API
   disabled by policy. There, **Sync Teams Button** in the menu falls back to pressing
   the real Mute button through the Accessibility API. It is off by default, runs off
   the main thread, and never blocks a keypress.

Muting never depends on 2 or 3. If Teams is closed, the API is blocked and Accessibility
is off, the shortcut still silences the microphone — you only lose the indicator inside
the Teams window.

### Quitting never leaves your mic dead

A HAL mute outlives the process that set it, so a crash used to leave the microphone
silent with nothing in the macOS UI to explain it. MacMute records what each device
looked like before it touched anything, restores that on quit and on `SIGTERM`/`SIGINT`,
and re-checks it on the next launch if it was killed outright.

## Requirements

- macOS 13 or later
- No permissions required
- Microsoft Teams optional — the audio device layer handles everything without it

## Build from source

Swift Package Manager, no dependencies. Xcode command line tools are enough.

```bash
git clone https://github.com/TuanBT/MacMute.git
cd MacMute
swift test          # muting logic, against devices that misbehave
./build.sh          # builds dist/MacMute.app
```

The decisions about what to mute live in `Sources/MacMuteCore`, free of CoreAudio, so
they can be tested against a fake device that accepts writes and ignores them — which
is how a real one behaves.

See [`ReleaseUtils/`](ReleaseUtils/) for the full release pipeline. Pushing a `v*` tag
builds and publishes a release from GitHub Actions.

## License

[MIT](LICENSE)
