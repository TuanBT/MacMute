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

    /// One line per decision and per device outcome. Called from whichever thread did
    /// the work, so the receiver must not assume the main one.
    public var onLog: ((String) -> Void)?

    /// `deafDevices` is the only state the deferred pass touches, and that pass runs
    /// off the main thread.
    private let lock = NSLock()

    /// Bumped on every call. A deferred pass whose generation is stale is skipped:
    /// pressing the shortcut repeatedly would otherwise queue a batch of slow writes
    /// per press, and a Bluetooth device costs milliseconds each.
    private var generation = 0

    /// When each device last had a mute of ours put back, within the current mute.
    /// Main thread only, like the listener that feeds it.
    private var corrections: [String: [TimeInterval]] = [:]

    /// More than this many put-backs inside `correctionWindow` means the device is
    /// fighting us, and the mute property is abandoned for the volume.
    public static let maxCorrections = 5
    public static let correctionWindow: TimeInterval = 10

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
        // Each mute starts with a clean slate: a device that fought the last one may
        // well behave this time.
        corrections = [:]

        let devices = manageableDevices()

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
        // Taken here, on the caller's thread, because the deferred pass must not ask the
        // backend: what it knows about capture belongs to the main thread.
        let inUse = Set(capturing.map(\.id))

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
            guard drive(muted, device, snapshot, inUse: inUse.contains(device.id)) else { continue }
            anyApplied = true
            if !muted { restored.append(device.uid) }
        }

        let verb = muted ? "mute" : "unmute"
        let urgentUIDs: [String] = urgent.map(\.uid)
        let restUIDs: [String] = rest.map(\.uid)
        onLog?("engine: \(verb) urgent=\(urgentUIDs) deferred=\(restUIDs) applied=\(anyApplied)")

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
        if !muted {
            forget(restored)
            _ = prune()
        }
        isMuted = muted
        publishBaseline()

        return anyApplied
    }

    /// Moves one device to `muted`, or back to the baseline when unmuting.
    ///
    /// `inUse` is whether something is capturing from it. An unmute is the user asking
    /// to be heard, so that device comes back live whatever it was wearing when the
    /// mute began — and what it was wearing was usually not the user's doing. Teams
    /// writes its own mute into the device it uses and leaves it there when it moves to
    /// another; recorded as "the user had it muted", that mute came back on every
    /// unmute, 194 times in one week of logs. Once it was the microphone a call was
    /// using: an unmute that turned the icon green and let nobody hear a word.
    ///
    /// A device nothing is listening through keeps the mute it was found with, which is
    /// the rule everywhere else: the app does not take off a mute it did not put on.
    private func drive(_ muted: Bool, _ device: AudioDeviceInfo,
                       _ baseline: [String: Baseline], inUse: Bool = false) -> Bool {
        guard !muted else { return apply(muted: true, to: device) }

        backend.stopVolumeGuard(device.id)
        guard let saved = baseline[device.uid] else {
            onLog?("engine:   \(device.uid): no baseline, clearing")
            // Appeared after we muted, so it was never the user's own mute.
            return apply(muted: false, to: device)
        }
        let restoreMuted = saved.muted && !inUse
        if saved.muted && inUse {
            onLog?("engine:   \(device.uid): was muted when found, but it is in use, opening it")
        }
        var applied = false
        if device.muteSettable, backend.setMute(device.id, restoreMuted) { applied = true }
        if let volume = saved.volume {
            if backend.setVolume(device.id, volume) { applied = true }
        } else if let current = backend.volume(of: device.id), current <= 0.0001 {
            // The level never reached the baseline — a device still negotiating its link
            // answers one read and not the next — and it is sitting at zero, which only
            // we would have done. Left there it is a dead microphone that the mute flag,
            // Teams and the menu bar all agree is live.
            if backend.setVolume(device.id, 1.0) { applied = true }
        }
        let level: String = saved.volume.map { String($0) } ?? "nil"
        let outcome = applied ? "ok" : "FAILED"
        onLog?("engine:   \(device.uid): restore to muted=\(restoreMuted) volume=\(level) -> \(outcome)")
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

    /// Per-process aggregate devices carry their client's pid in the UID, so one that
    /// has gone never comes back under the same name.
    public static func isEphemeral(_ uid: String) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate-")
    }

    /// The devices worth writing to: something to write, and a record of it being heard.
    ///
    /// The per-process aggregates macOS builds for voice processing have neither a mute
    /// nor a level. Each one used to get a baseline entry that no restore could ever
    /// clear, because there was nothing to restore, and Bug B rightly keeps an entry
    /// that was not restored — so they piled up: eighty of them in one week, every one
    /// rewritten to disk inside every keypress. A device known to ignore writes is left
    /// out for the same reason, and for one more: the guard used to treat its discarded
    /// write as a mute "lost", and raised the critical alert eight times in 25 seconds
    /// over the virtual Teams device, which nothing was even capturing from.
    private func manageableDevices() -> [AudioDeviceInfo] {
        lock.lock()
        let deaf = deafDevices
        lock.unlock()
        return backend.inputDevices().filter { device in
            (device.muteSettable || device.hasWritableVolume) && !deaf.contains(device.uid)
        }
    }

    /// Drops entries no restore can ever settle: a device that ignores writes, a device
    /// with nothing to write, and a per-process aggregate that has gone. Everything
    /// else that is away keeps its entry, which is Bug B's whole point. Returns whether
    /// anything went.
    private func prune() -> Bool {
        let present = backend.inputDevices()
        let usable = Set(manageableDevices().map(\.uid))
        let here = Set(present.map(\.uid))
        lock.lock()
        let stale = baseline.keys.filter { uid in
            if deafDevices.contains(uid) { return true }
            return here.contains(uid) ? !usable.contains(uid) : Self.isEphemeral(uid)
        }
        for uid in stale { baseline.removeValue(forKey: uid) }
        lock.unlock()
        if !stale.isEmpty { onLog?("engine: forgot \(stale.count) entries nothing can restore") }
        return !stale.isEmpty
    }

    /// Mutes anything that arrived while we were already muted, so plugging in a
    /// headset does not silently hand back a live microphone.
    public func adoptNewDevices() {
        let devices = manageableDevices()
        let known = currentBaseline()

        guard isMuted else {
            // Not muted, so anything still carrying an entry is a device that was away
            // when the unmute ran. It has come back still wearing our mute and nothing
            // else is ever going to take it off.
            guard !known.isEmpty else { return }
            var done: [String] = []
            for device in devices where known[device.uid] != nil {
                let inUse = backend.isCapturing(device.id)
                if drive(false, device, known, inUse: inUse) { done.append(device.uid) }
            }
            forget(done)
            let pruned = prune()
            guard pruned || !done.isEmpty else { return }
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

    public enum Reassertion: Equatable {
        /// Nothing to do: the app is live, the device still reads muted, or the mute
        /// on it was never ours.
        case notNeeded
        /// The mute property was written back and reads muted again.
        case remuted
        /// The mute property would not stay put, so the device is held at zero volume
        /// under the volume guard instead.
        case fellBackToVolume
        /// Neither held. The device is live and nothing here can close it.
        case failed
    }

    /// Called whenever a device's mute property changes. Puts back a mute of ours that
    /// something else took off while the app still says muted.
    ///
    /// Without this the red icon is a claim about the past: a Bluetooth headset
    /// switching profile, a driver resetting on a format change, or another app writing
    /// the property all open the microphone with nothing in the app noticing. That is
    /// the one failure worse than no mute at all — you speak because you believe you
    /// cannot be heard.
    ///
    /// Our own writes fire the same notification, which is why the test is "reads live
    /// while muted" and never "something changed". The window is the backstop against a
    /// device that keeps flipping back: past it, the volume takes over.
    ///
    /// Putting the mute back is only half the answer when the device is in use, because
    /// the most common thing taking it off is Teams: it writes its own mute into the
    /// device, so unmuting inside Teams clears ours. Whether to keep the mute or follow
    /// Teams is decided above this, by asking Teams — the mute goes back first, so the
    /// microphone is never open while that question is being answered.
    @discardableResult
    public func reassertMute(_ id: UInt32, now: TimeInterval) -> Reassertion {
        guard isMuted, backend.mute(of: id) == false,
              let device = backend.inputDevices().first(where: { $0.id == id }),
              !isDeaf(device.uid),
              currentBaseline()[device.uid] != nil else { return .notNeeded }

        var recent = (corrections[device.uid] ?? []).filter { now - $0 < Self.correctionWindow }
        recent.append(now)
        corrections[device.uid] = recent

        if recent.count <= Self.maxCorrections, device.muteSettable,
           backend.setMute(id, true), backend.mute(of: id) == true {
            onLog?("guard: \(device.uid) was unmuted by something else, muted again "
                   + "(\(recent.count) in \(Int(Self.correctionWindow))s)")
            return .remuted
        }

        // The volume is the second lock, and the volume guard already knows how to hold
        // it against Teams raising the gain.
        if device.hasWritableVolume, backend.setVolume(id, 0),
           let level = backend.volume(of: id), level <= 0.0001 {
            backend.startVolumeGuard(id)
            onLog?("guard: \(device.uid) will not stay muted, holding it at volume 0 instead")
            return .fellBackToVolume
        }
        onLog?("guard: ⚠︎ \(device.uid) was unmuted and cannot be closed again — DEVICE IS LIVE")
        return .failed
    }

    /// Takes the mute off every microphone something is listening through, for when the
    /// app and Teams both say live and the device disagrees. Returns what it opened.
    ///
    /// The app does not lift a mute it did not put on, as a rule, and this is the one
    /// place the rule protects nobody. Teams shows you live, the menu bar shows you
    /// live, and the only thing still muted is the device the call is using — left that
    /// way by something else, most often Teams itself, which writes its mute into a
    /// device and leaves it there when it moves to another. The log shows calls opening
    /// on a microphone in that state while the app said live: a dead call that every
    /// indicator on screen calls live.
    public func openCapturingDevices() -> [String] {
        guard !isMuted else { return [] }
        var opened: [String] = []
        for device in backend.inputDevices() where backend.isCapturing(device.id) {
            guard device.muteSettable, !isDeaf(device.uid), backend.mute(of: device.id) == true,
                  backend.setMute(device.id, false), backend.mute(of: device.id) == false
            else { continue }
            opened.append(device.uid)
        }
        if !opened.isEmpty { onLog?("engine: opened \(opened), muted from outside while live") }
        return opened
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

    private func isDeaf(_ uid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deafDevices.contains(uid)
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

    /// Once marked, nothing here writes to the device again, so whatever the failed
    /// attempt did manage is undone first — a level that went down to 0.01 rather than
    /// zero would otherwise stay there for good. Then its entry goes: it records nothing
    /// we still owe, and keeping it is what let the guard mistake the device's discarded
    /// writes for a lost mute.
    private func markDeaf(_ device: AudioDeviceInfo) {
        if let saved = currentBaseline()[device.uid] {
            if device.muteSettable { _ = backend.setMute(device.id, saved.muted) }
            if let level = saved.volume, device.hasWritableVolume { _ = backend.setVolume(device.id, level) }
        }
        lock.lock()
        deafDevices.insert(device.uid)
        baseline.removeValue(forKey: device.uid)
        let deaf = deafDevices
        lock.unlock()
        onDeafDevicesChange?(deaf)
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
        let verb = muted ? "mute" : "unmute"
        if deaf {
            onLog?("engine:   \(device.uid): \(verb) skipped, known to ignore writes")
            return false
        }

        // A noErr return proves nothing. The virtual "Microsoft Teams Audio" device
        // reports mute and volume as settable, accepts either write, and discards it.
        if device.muteSettable, backend.setMute(device.id, muted) {
            let readback = backend.mute(of: device.id)
            if readback == muted {
                onLog?("engine:   \(device.uid): \(verb) via mute property, verified")
                return true
            }
            let text: String = readback.map { String($0) } ?? "nil"
            onLog?("engine:   \(device.uid): mute write accepted but reads back \(text), trying volume")
        }

        guard device.hasWritableVolume, let volume = backend.volume(of: device.id)
        else {
            onLog?("engine:   \(device.uid): \(verb) FAILED, no usable mute or volume")
            if muted { markDeaf(device) }
            return false
        }
        guard muted else {
            // Writing back the level just read is a no-op that reports success, and when
            // that level is zero the microphone stays dead while the call returns true.
            let ok = backend.setVolume(device.id, volume <= 0.0001 ? 1.0 : volume)
            onLog?("engine:   \(device.uid): unmute via volume -> \(ok ? "ok" : "FAILED")")
            return ok
        }

        _ = backend.setVolume(device.id, 0)
        guard let readback = backend.volume(of: device.id), readback <= 0.0001 else {
            let level: String = backend.volume(of: device.id).map { String($0) } ?? "nil"
            onLog?("engine:   \(device.uid): mute FAILED, volume stays at \(level), marking deaf")
            markDeaf(device)
            return false
        }
        // Only guard a device that demonstrably honours the write, because Teams
        // raises input gain when it joins a meeting and would otherwise reopen the mic.
        backend.startVolumeGuard(device.id)
        onLog?("engine:   \(device.uid): mute via volume 0, verified, guard on")
        return true
    }
}
