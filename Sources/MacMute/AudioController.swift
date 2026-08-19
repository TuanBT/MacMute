import CoreAudio
import Foundation
import MacMuteCore

/// Mutes every input device through the CoreAudio HAL.
///
/// This is the layer that actually guarantees silence: no permission, about 1.5 ms of
/// writes for a typical set of devices, and it cannot be undone by whichever app is
/// capturing. Teams rewrites input *volume* when it joins a meeting (measured: 0.88 to
/// 1.00) but leaves the mute property alone, which is why mute is preferred, why the
/// volume fallback re-asserts itself, and why every write is confirmed by reading back.
///
/// The decisions live in `MuteEngine`; this type is the CoreAudio half — device
/// discovery, property access, and the listeners that keep the icon current without
/// polling anything.
final class AudioController: AudioBackend {

    private static let baselineKey = "muteBaseline"
    private static let deafKey = "devicesIgnoringWrites"

    private lazy var engine = MuteEngine(backend: self)

    /// Fires when any input device starts or stops being captured, and when the set of
    /// devices changes. This is what turns the menu bar icon green.
    var onInputActivityChange: (() -> Void)?

    /// What each device can do, resolved once per device-list change. Probing this on
    /// every keypress cost tens of milliseconds against about 1.5 ms for the writes.
    private struct CachedDevice {
        var info: AudioDeviceInfo
        var volumeTargets: [VolumeTarget]
    }

    /// Where a device's input level can be written. Some devices expose no writable
    /// `VolumeScalar` channel but do accept the AudioHardwareService virtual main
    /// volume, so both are probed before a device is declared unmutable.
    private struct VolumeTarget {
        var selector: AudioObjectPropertySelector
        var element: UInt32
    }

    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume, not exposed to Swift.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766d7663  // 'vmvc'

    private let deferQueue = DispatchQueue(label: "com.tuanbt.macmute.audio.deferred",
                                           qos: .userInitiated)
    private var cache: [UInt32: CachedDevice] = [:]
    private var order: [UInt32] = []
    private var activityListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var volumeGuards: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    init() {
        refreshCache()
        refreshInputActivity()
        engine.onBaselineChange = { [weak self] baseline in self?.persist(baseline) }
        engine.seedDeafDevices(Set(UserDefaults.standard.stringArray(forKey: Self.deafKey) ?? []))
        engine.onDeafDevicesChange = { uids in
            UserDefaults.standard.set(Array(uids).sorted(), forKey: Self.deafKey)
        }
        recoverFromCrashIfNeeded()
        observeDeviceList()
        refreshActivityListeners()
    }

    // MARK: - Public surface

    var isMuted: Bool { engine.isMuted }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool { engine.setMuted(muted) }

    /// True while any app is capturing from any input device — the same signal behind
    /// the orange dot macOS shows in the menu bar.
    ///
    /// Stored rather than probed. Asking the HAL costs a round trip per device, a
    /// Bluetooth headset answers slowly, and this is read several times per redraw.
    /// The listeners below already tell us exactly when it changes.
    private(set) var isInputActive = false
    private var capturingDevices: Set<UInt32> = []

    private func refreshInputActivity() {
        capturingDevices = Set(order.filter { isRunning($0) })
        isInputActive = !capturingDevices.isEmpty
    }

    /// Called on quit and from the signal handlers. A HAL mute outlives the process
    /// that set it, so skipping this leaves the microphone dead with nothing in the
    /// macOS UI to explain it.
    func restoreOnExit() {
        guard engine.isMuted else { return }
        engine.setMuted(false)
    }

    // MARK: - AudioBackend

    func inputDevices() -> [AudioDeviceInfo] { order.compactMap { cache[$0]?.info } }

    func mute(of id: UInt32) -> Bool? {
        var address = muteAddress()
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    func setMute(_ id: UInt32, _ muted: Bool) -> Bool {
        guard cache[id]?.info.muteSettable == true else { return false }
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func volume(of id: UInt32) -> Float? {
        for target in cache[id]?.volumeTargets ?? [] {
            var address = volumeAddress(target)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    func setVolume(_ id: UInt32, _ volume: Float) -> Bool {
        var applied = false
        for target in cache[id]?.volumeTargets ?? [] {
            var address = volumeAddress(target)
            var value = Float32(volume)
            if AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                applied = true
            }
        }
        return applied
    }

    /// Keeps a volume-muted device at zero, because Teams raises input gain when it
    /// joins a meeting and would otherwise quietly reopen the microphone.
    ///
    /// Our own write fires this notification too, so the test has to be "is the level
    /// above zero" and never "did something change". The strike count is the backstop
    /// for a device that never settles: after a few failed corrections the guard
    /// removes itself instead of spinning against coreaudiod.
    func startVolumeGuard(_ id: UInt32) {
        guard volumeGuards[id] == nil, let targets = cache[id]?.volumeTargets,
              let first = targets.first else { return }
        var strikes = 0
        var address = volumeAddress(first)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.engine.isMuted else { return }
            guard let value = self.volume(of: id), value > 0.0001 else {
                strikes = 0
                return
            }
            strikes += 1
            guard strikes <= 5 else {
                self.stopVolumeGuard(id)
                return
            }
            _ = self.setVolume(id, 0)
        }
        if AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block) == noErr {
            volumeGuards[id] = block
        }
    }

    /// Read from the same listener-maintained set as `isInputActive`. Probing the HAL
    /// here would put a round trip per device back onto the keypress.
    func isCapturing(_ id: UInt32) -> Bool { capturingDevices.contains(id) }

    /// The devices nobody is listening through are silenced just after the keypress
    /// returns instead of during it. Writing to a Bluetooth or virtual device costs
    /// many times what the built-in microphone does, and none of it affects whether
    /// you are audible right now.
    func deferWork(_ work: @escaping () -> Void) {
        deferQueue.async(execute: work)
    }

    func stopVolumeGuard(_ id: UInt32) {
        guard let block = volumeGuards.removeValue(forKey: id),
              let first = cache[id]?.volumeTargets.first else { return }
        var address = volumeAddress(first)
        AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
    }

    // MARK: - Persistence

    /// Stored as a plain property list rather than JSON. This runs inside the keypress
    /// — the baseline has to reach disk before the device is written, or a crash in
    /// between leaves a mute nothing will undo — and JSONEncoder measured about a
    /// millisecond even for a single entry.
    private func persist(_ baseline: [String: MuteEngine.Baseline]) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            Timing.note(String(format: "    persist %.2f ms (%d devices)",
                               Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
                               baseline.count))
        }
        guard !baseline.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.baselineKey)
            return
        }
        var plist: [String: [String: Any]] = [:]
        for (uid, entry) in baseline {
            var fields: [String: Any] = ["m": entry.muted]
            if let volume = entry.volume { fields["v"] = Double(volume) }
            plist[uid] = fields
        }
        UserDefaults.standard.set(plist, forKey: Self.baselineKey)
    }

    private func recoverFromCrashIfNeeded() {
        var saved: [String: MuteEngine.Baseline] = [:]
        if let plist = UserDefaults.standard.dictionary(forKey: Self.baselineKey) {
            for (uid, value) in plist {
                guard let fields = value as? [String: Any],
                      let muted = fields["m"] as? Bool else { continue }
                saved[uid] = MuteEngine.Baseline(muted: muted,
                                                 volume: (fields["v"] as? Double).map(Float.init))
            }
        } else if let data = UserDefaults.standard.data(forKey: Self.baselineKey),
                  let legacy = try? JSONDecoder().decode([String: MuteEngine.Baseline].self,
                                                         from: data) {
            // Written by an earlier build; restore it, then it is gone for good.
            saved = legacy
        }
        engine.restore(from: saved)
    }

    // MARK: - Device discovery

    private func refreshCache() {
        var next: [UInt32: CachedDevice] = [:]
        var nextOrder: [UInt32] = []
        for device in enumerateInputDevices() {
            guard let uid = uid(of: device) else { continue }
            let targets = volumeTargets(device)
            next[device] = CachedDevice(
                info: AudioDeviceInfo(id: device, uid: uid,
                                      muteSettable: isMuteSettable(device),
                                      hasWritableVolume: !targets.isEmpty),
                volumeTargets: targets)
            nextOrder.append(device)
        }
        cache = next
        order = nextOrder
    }

    private func enumerateInputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { hasInputChannels($0) }
    }

    private func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return false }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        var channels: UInt32 = 0
        withUnsafePointer(to: &list.pointee.mBuffers) { pointer in
            for buffer in UnsafeBufferPointer(start: pointer, count: Int(list.pointee.mNumberBuffers)) {
                channels += buffer.mNumberChannels
            }
        }
        return channels > 0
    }

    /// UIDs are stable across reboots; AudioDeviceIDs are not, and the baseline has to
    /// survive in UserDefaults.
    private func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func isMuteSettable(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        return isSettable(device, &address)
    }

    /// The master element covers every channel, so stop there when it is writable.
    /// Falls back to the virtual main volume, the only writable level on some USB and
    /// aggregate devices.
    private func volumeTargets(_ device: AudioDeviceID) -> [VolumeTarget] {
        var targets: [VolumeTarget] = []
        for channel: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = volumeAddress(VolumeTarget(selector: kAudioDevicePropertyVolumeScalar,
                                                     element: channel))
            guard isSettable(device, &address) else { continue }
            targets.append(VolumeTarget(selector: kAudioDevicePropertyVolumeScalar,
                                        element: channel))
            if channel == kAudioObjectPropertyElementMain { break }
        }
        guard targets.isEmpty else { return targets }

        var address = AudioObjectPropertyAddress(mSelector: Self.virtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if isSettable(device, &address) {
            targets.append(VolumeTarget(selector: Self.virtualMainVolume,
                                        element: kAudioObjectPropertyElementMain))
        }
        return targets
    }

    private func isSettable(_ device: AudioDeviceID,
                            _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    // MARK: - Listeners

    private func observeDeviceList() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            self.refreshCache()
            // A device plugged in while muted must be muted too, or it hands back a
            // live microphone the user believes is off.
            self.engine.adoptNewDevices()
            self.refreshActivityListeners()
            self.refreshInputActivity()
            self.onInputActivityChange?()
        }
    }

    private func refreshActivityListeners() {
        let devices = Set(order)
        for (device, block) in activityListeners where !devices.contains(device) {
            var address = runningAddress()
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
            activityListeners.removeValue(forKey: device)
        }
        for device in devices where activityListeners[device] == nil {
            var address = runningAddress()
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.refreshInputActivity()
                self.onInputActivityChange?()
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
                activityListeners[device] = block
            }
        }
    }

    private func isRunning(_ device: AudioDeviceID) -> Bool {
        var address = runningAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    // MARK: - Addresses

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func volumeAddress(_ target: VolumeTarget) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: target.selector,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: target.element)
    }

    private func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
