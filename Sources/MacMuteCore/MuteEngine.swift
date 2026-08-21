import Foundation

/// What the engine needs to know about one input device, resolved by the backend.
public struct AudioDeviceInfo: Equatable {
    public let id: UInt32
    public let uid: String
    /// The device reports a writable `kAudioDevicePropertyMute`.
    public let muteSettable: Bool
    /// The device has at least one writable level, either a volume channel or the
    /// AudioHardwareService virtual main volume.
    public let hasWritableVolume: Bool

    public init(id: UInt32, uid: String, muteSettable: Bool, hasWritableVolume: Bool) {
        self.id = id
        self.uid = uid
        self.muteSettable = muteSettable
        self.hasWritableVolume = hasWritableVolume
    }
}

/// The HAL operations the engine performs, behind a protocol so the decision logic can
/// be tested against devices that lie — which real ones do.
public protocol AudioBackend: AnyObject {
    func inputDevices() -> [AudioDeviceInfo]
    func mute(of id: UInt32) -> Bool?
    func setMute(_ id: UInt32, _ muted: Bool) -> Bool
    func volume(of id: UInt32) -> Float?
    func setVolume(_ id: UInt32, _ volume: Float) -> Bool
    func startVolumeGuard(_ id: UInt32)
    func stopVolumeGuard(_ id: UInt32)

    /// True while some app is capturing from this device. Only these decide whether
    /// you are audible right now, so only these are worth blocking a keypress on.
    func isCapturing(_ id: UInt32) -> Bool

    /// Runs work that need not finish before the keypress returns. Tests run it inline.
    func deferWork(_ work: @escaping () -> Void)
}

/// Decides what to write to which device, and what to put back afterwards.
///
/// Kept free of CoreAudio so the awkward cases can be tested directly: a device that
/// accepts a write and ignores it, a device the user had already muted, a device
/// plugged in while muted, and a device with no usable mute at all. Every one of those
/// has produced a real bug.
public final class MuteEngine {

    public struct Baseline: Codable, Equatable {
        public var muted: Bool
        public var volume: Float?

        public init(muted: Bool, volume: Float?) {
            self.muted = muted
            self.volume = volume
        }
    }

    public private(set) var isMuted = false
    public private(set) var baseline: [String: Baseline] = [:]

    /// Devices that accept a write and then ignore it. Re-asserting against one of
    /// these spins: the guard writes, the device does not change, the change
    /// notification fires, the guard writes again.
    public private(set) var deafDevices: Set<String> = []

    private let backend: AudioBackend
    public var onBaselineChange: (([String: Baseline]) -> Void)?

    /// `deafDevices` is the only state the deferred pass touches, and that pass runs
    /// off the main thread.
    private let lock = NSLock()

    /// Bumped on every call. A deferred pass whose generation is stale is skipped:
    /// pressing the shortcut repeatedly would otherwise queue a batch of slow writes
    /// per press, and a Bluetooth device costs milliseconds each.
    private var generation = 0

    public init(backend: AudioBackend) {
        self.backend = backend
    }

    /// Drives every input device to `muted`. Returns false when nothing accepted the
    /// change, which is the one case the caller must not report as success.
    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool {
        lock.lock()
        generation += 1
        let epoch = generation
        lock.unlock()

        let devices = backend.inputDevices()

        // Reading the baseline is cheap and has to happen before anything is written,
        // so it covers every device. The writes are what cost — a USB device is about
        // six times slower than the built-in microphone, and a virtual one twelve.
        //
        // When something is capturing, only that device decides whether you are
        // audible, so it is the only one worth blocking on and the rest follow a moment
        // later. When nothing is capturing there is no such device to point at, and no
        // basis to claim success from a write that has not happened yet, so everything
        // runs inline — nobody is listening, and nobody is waiting either.
        var capturing: [AudioDeviceInfo] = []
        var idle: [AudioDeviceInfo] = []
        for device in devices {
            if backend.isCapturing(device.id) { capturing.append(device) } else { idle.append(device) }
        }
        let urgent = capturing.isEmpty ? devices : capturing
        let rest = capturing.isEmpty ? [] : idle

        // Reading a baseline is two more round trips per device, so the idle ones are
        // read in the deferred pass, immediately before they are written.
        //
        // Every mute records what it finds, not only the first one. Skipping this
        // whenever the baseline merely happened to be non-empty left a device muted with
        // nothing written down, and the next pass then read that mute back and recorded
        // it as the state the user had chosen — cementing it. `recordBaseline` already
        // declines to overwrite an entry, so the check this replaces bought nothing else.
        if muted {
            for device in urgent { recordBaseline(device) }
        }

        let snapshot = currentBaseline()
        var anyApplied = false
        var restored: [String] = []
        for device in urgent {
            guard drive(muted, device, snapshot) else { continue }
            anyApplied = true
            if !muted { restored.append(device.uid) }
        }

        let deferred = rest
        backend.deferWork { [weak self] in
            guard let self else { return }
            guard muted else {
                // `snapshot` was taken before setMuted forgot these devices, and is the
                // only copy of what they looked like.
                var done: [String] = []
                for device in deferred {
                    guard self.isCurrent(epoch) else { break }
                    if self.drive(false, device, snapshot) { done.append(device.uid) }
                }
                self.forget(done)
                self.publishBaseline()
                return
            }
            // The generation is re-read before every write rather than once on entry.
            // A pass that only checked at the top kept muting devices after an unmute
            // had already put them back, leaving them silent with the app — and every
            // indicator in macOS — reporting a live microphone.
            for device in deferred {
                guard self.isCurrent(epoch) else { return }
                self.recordBaseline(device)
            }
            guard self.isCurrent(epoch) else { return }
            // Publish before writing: a crash between the two would otherwise leave
            // these devices muted with nothing on disk to undo them.
            self.publishBaseline()
            let saved = self.currentBaseline()
            for device in deferred {
                guard self.isCurrent(epoch) else { return }
                _ = self.drive(true, device, saved)
            }
        }

        // Bug B: only devices actually put back are forgotten. One that could not be
        // reached — unplugged, asleep, gone with the app that summoned it — keeps its
        // entry, so there is still something to restore it with when it returns.
        if !muted { forget(restored) }
        isMuted = muted
        publishBaseline()

        return anyApplied
    }

    /// Moves one device to `muted`, or back to the baseline when unmuting.
    private func drive(_ muted: Bool, _ device: AudioDeviceInfo,
                       _ baseline: [String: Baseline]) -> Bool {
        guard !muted else { return apply(muted: true, to: device) }

        backend.stopVolumeGuard(device.id)
        guard let saved = baseline[device.uid] else {
            // Appeared after we muted, so it was never the user's own mute.
            return apply(muted: false, to: device)
        }
        var applied = false
        if device.muteSettable, backend.setMute(device.id, saved.muted) { applied = true }
        if let volume = saved.volume {
            if backend.setVolume(device.id, volume) { applied = true }
        } else if let current = backend.volume(of: device.id), current <= 0.0001 {
            // The level never reached the baseline — a device still negotiating its link
            // answers one read and not the next — and it is sitting at zero, which only
            // we would have done. Left there it is a dead microphone that the mute flag,
            // Teams and the menu bar all agree is live.
            if backend.setVolume(device.id, 1.0) { applied = true }
        }
        return applied
    }

    /// Drops the entries for devices that are demonstrably back the way we found them.
    /// Everything else keeps its entry: it is the only record that a restore is owed.
    private func forget(_ uids: [String]) {
        guard !uids.isEmpty else { return }
        lock.lock()
        for uid in uids { baseline.removeValue(forKey: uid) }
        lock.unlock()
    }

    /// Mutes anything that arrived while we were already muted, so plugging in a
    /// headset does not silently hand back a live microphone.
    public func adoptNewDevices() {
        let devices = backend.inputDevices()
        let known = currentBaseline()

        guard isMuted else {
            // Not muted, so anything still carrying an entry is a device that was away
            // when the unmute ran. It has come back still wearing our mute and nothing
            // else is ever going to take it off.
            guard !known.isEmpty else { return }
            var done: [String] = []
            for device in devices where known[device.uid] != nil {
                if drive(false, device, known) { done.append(device.uid) }
            }
            guard !done.isEmpty else { return }
            forget(done)
            publishBaseline()
            return
        }

        var adopted = false
        for device in devices where known[device.uid] == nil {
            recordBaseline(device)
            _ = apply(muted: true, to: device)
            adopted = true
        }
        if adopted { publishBaseline() }
    }

    /// Puts back a baseline recovered from disk after the process was killed while muted.
    public func restore(from saved: [String: Baseline]) {
        guard !saved.isEmpty else { return }
        baseline = saved
        isMuted = true
        setMuted(false)
    }

    // MARK: - One device

    private func isCurrent(_ epoch: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == generation
    }

    private func recordBaseline(_ device: AudioDeviceInfo) {
        // A device still bringing its link up answers one read and not the next, and a
        // baseline with no level in it has nothing to put back. One retry is cheap and
        // it is the difference between restoring the level the user had and guessing.
        var level = backend.volume(of: device.id)
        if level == nil, device.hasWritableVolume { level = backend.volume(of: device.id) }
        let entry = Baseline(muted: backend.mute(of: device.id) ?? false, volume: level)
        lock.lock()
        if baseline[device.uid] == nil { baseline[device.uid] = entry }
        lock.unlock()
    }

    private func currentBaseline() -> [String: Baseline] {
        lock.lock(); defer { lock.unlock() }
        return baseline
    }

    private func publishBaseline() {
        onBaselineChange?(currentBaseline())
    }

    private func markDeaf(_ uid: String) {
        lock.lock()
        deafDevices.insert(uid)
        lock.unlock()
        onDeafDevicesChange?(deafDevices)
    }

    /// Persisted so a device that ignores writes is never retried, not even once per
    /// launch — the virtual Teams device is the slowest of the lot to write to.
    public var onDeafDevicesChange: ((Set<String>) -> Void)?

    public func seedDeafDevices(_ uids: Set<String>) {
        lock.lock()
        deafDevices = uids
        lock.unlock()
    }

    private func apply(muted: Bool, to device: AudioDeviceInfo) -> Bool {
        lock.lock()
        let deaf = deafDevices.contains(device.uid)
        lock.unlock()
        if deaf { return false }

        // A noErr return proves nothing. The virtual "Microsoft Teams Audio" device
        // reports mute and volume as settable, accepts either write, and discards it.
        if device.muteSettable, backend.setMute(device.id, muted),
           backend.mute(of: device.id) == muted {
            return true
        }

        guard device.hasWritableVolume, let volume = backend.volume(of: device.id)
        else {
            if muted { markDeaf(device.uid) }
            return false
        }
        guard muted else {
            // Writing back the level just read is a no-op that reports success, and when
            // that level is zero the microphone stays dead while the call returns true.
            return backend.setVolume(device.id, volume <= 0.0001 ? 1.0 : volume)
        }

        _ = backend.setVolume(device.id, 0)
        guard let readback = backend.volume(of: device.id), readback <= 0.0001 else {
            markDeaf(device.uid)
            return false
        }
        // Only guard a device that demonstrably honours the write, because Teams
        // raises input gain when it joins a meeting and would otherwise reopen the mic.
        backend.startVolumeGuard(device.id)
        return true
    }
}
