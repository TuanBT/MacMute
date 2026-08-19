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

    public init(backend: AudioBackend) {
        self.backend = backend
    }

    /// Drives every input device to `muted`. Returns false when nothing accepted the
    /// change, which is the one case the caller must not report as success.
    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool {
        let devices = backend.inputDevices()
        var anyApplied = false

        if muted {
            // Capture the baseline before anything is touched, and only once: a second
            // mute while already muted must not record our own zeroes as the baseline.
            if baseline.isEmpty {
                for device in devices {
                    baseline[device.uid] = Baseline(muted: backend.mute(of: device.id) ?? false,
                                                   volume: backend.volume(of: device.id))
                }
            }
            for device in devices where apply(muted: true, to: device) {
                anyApplied = true
            }
        } else {
            for device in devices {
                backend.stopVolumeGuard(device.id)
                guard let saved = baseline[device.uid] else {
                    // Appeared after we muted, so it was never the user's own mute.
                    if apply(muted: false, to: device) { anyApplied = true }
                    continue
                }
                if device.muteSettable, backend.setMute(device.id, saved.muted) {
                    anyApplied = true
                }
                if let volume = saved.volume, backend.setVolume(device.id, volume) {
                    anyApplied = true
                }
            }
            baseline.removeAll()
        }

        isMuted = muted
        onBaselineChange?(baseline)
        return anyApplied
    }

    /// Mutes anything that arrived while we were already muted, so plugging in a
    /// headset does not silently hand back a live microphone.
    public func adoptNewDevices() {
        guard isMuted else { return }
        for device in backend.inputDevices() where baseline[device.uid] == nil {
            baseline[device.uid] = Baseline(muted: backend.mute(of: device.id) ?? false,
                                            volume: backend.volume(of: device.id))
            _ = apply(muted: true, to: device)
        }
        onBaselineChange?(baseline)
    }

    /// Puts back a baseline recovered from disk after the process was killed while muted.
    public func restore(from saved: [String: Baseline]) {
        guard !saved.isEmpty else { return }
        baseline = saved
        isMuted = true
        setMuted(false)
    }

    // MARK: - One device

    private func apply(muted: Bool, to device: AudioDeviceInfo) -> Bool {
        if deafDevices.contains(device.uid) { return false }

        // A noErr return proves nothing. The virtual "Microsoft Teams Audio" device
        // reports mute and volume as settable, accepts either write, and discards it.
        if device.muteSettable, backend.setMute(device.id, muted),
           backend.mute(of: device.id) == muted {
            return true
        }

        guard device.hasWritableVolume, let volume = backend.volume(of: device.id)
        else {
            if muted { deafDevices.insert(device.uid) }
            return false
        }
        guard muted else { return backend.setVolume(device.id, volume) }

        _ = backend.setVolume(device.id, 0)
        guard let readback = backend.volume(of: device.id), readback <= 0.0001 else {
            deafDevices.insert(device.uid)
            return false
        }
        // Only guard a device that demonstrably honours the write, because Teams
        // raises input gain when it joins a meeting and would otherwise reopen the mic.
        backend.startVolumeGuard(device.id)
        return true
    }
}
