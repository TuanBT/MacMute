import XCTest
@testable import MacMuteCore

/// Reproductions for a microphone left muted at the HAL with the app believing it is
/// live. Both were reported from the field: Teams keeps toggling its own button, the
/// icon stays green, and nobody can hear you until the machine is rebooted.
private struct FakeDevice {
    var uid: String
    var muteSettable: Bool
    var hasWritableVolume: Bool
    var capturing = false
    var muted = false
    var volume: Float? = 1.0
}

private final class FakeBackend: AudioBackend {
    var devices: [UInt32: FakeDevice] = [:]

    /// Fires inside a write, so a test can interleave a call from another thread at
    /// exactly the point the deferred pass reaches a given device.
    var onSetMute: ((UInt32, Bool) -> Void)?

    init(_ devices: [UInt32: FakeDevice]) { self.devices = devices }

    func inputDevices() -> [AudioDeviceInfo] {
        devices.keys.sorted().map { id in
            let device = devices[id]!
            return AudioDeviceInfo(id: id, uid: device.uid,
                                   muteSettable: device.muteSettable,
                                   hasWritableVolume: device.hasWritableVolume)
        }
    }

    func mute(of id: UInt32) -> Bool? { devices[id]?.muted }

    func setMute(_ id: UInt32, _ muted: Bool) -> Bool {
        guard var device = devices[id], device.muteSettable else { return false }
        device.muted = muted
        devices[id] = device
        onSetMute?(id, muted)
        return true
    }

    func volume(of id: UInt32) -> Float? { devices[id]?.volume }

    func setVolume(_ id: UInt32, _ volume: Float) -> Bool {
        guard var device = devices[id], device.hasWritableVolume else { return false }
        device.volume = volume
        devices[id] = device
        return true
    }

    func startVolumeGuard(_ id: UInt32) {}
    func stopVolumeGuard(_ id: UInt32) {}
    func isCapturing(_ id: UInt32) -> Bool { devices[id]?.capturing ?? false }

    var holdDeferred = false
    private var pending: [() -> Void] = []
    func deferWork(_ work: @escaping () -> Void) {
        if holdDeferred { pending.append(work) } else { work() }
    }
    func drain() {
        let work = pending
        pending = []
        work.forEach { $0() }
    }
}

final class StrandedMuteTests: XCTestCase {

    /// A device that was away when the unmute ran must still be put back when it
    /// returns. Unplug a headset while muted and its record used to be thrown out with
    /// the rest of the baseline, leaving it muted with nothing able to undo it.
    func testDeviceAbsentAtUnmuteIsRestoredWhenItComesBack() {
        let backend = FakeBackend([
            1: FakeDevice(uid: "BuiltInMicrophoneDevice", muteSettable: true,
                          hasWritableVolume: true),
            2: FakeDevice(uid: "41-42-FF-E9-0C-04:input", muteSettable: true,
                          hasWritableVolume: true, capturing: true),
        ])
        let engine = MuteEngine(backend: backend)

        engine.setMuted(true)
        XCTAssertTrue(backend.devices[2]!.muted)

        let headset = backend.devices.removeValue(forKey: 2)!   // unplugged, still muted
        engine.setMuted(false)

        XCTAssertFalse(engine.baseline.isEmpty,
                       "the record of a device we still owe a restore to must survive")

        backend.devices[2] = headset                            // back on the desk
        engine.adoptNewDevices()                                // the device-list listener

        XCTAssertFalse(backend.devices[2]!.muted, "it must come back live")
        XCTAssertTrue(engine.baseline.isEmpty, "and nothing is owed any more")
    }

    /// The deferred pass reads the generation before every write. One that checked only
    /// on entry kept muting devices after an unmute had already put them back.
    func testDeferredMutePassStopsWhenAnUnmuteSupersedesIt() {
        let backend = FakeBackend([
            1: FakeDevice(uid: "41-42-FF-E9-0C-04:input", muteSettable: true,
                          hasWritableVolume: true, capturing: true),
            2: FakeDevice(uid: "AppleUSBAudioEngine:K30", muteSettable: true,
                          hasWritableVolume: true),
            3: FakeDevice(uid: "BuiltInMicrophoneDevice", muteSettable: true,
                          hasWritableVolume: true),
        ])
        backend.holdDeferred = true
        let engine = MuteEngine(backend: backend)

        engine.setMuted(true)

        // Mid-loop, the call ends and the user unmutes from the main thread.
        backend.onSetMute = { [weak backend] id, muted in
            guard id == 2, muted, let backend else { return }
            backend.onSetMute = nil
            backend.devices[1]!.capturing = false
            engine.setMuted(false)
        }
        backend.drain()
        backend.drain()

        XCTAssertFalse(engine.isMuted)
        XCTAssertFalse(backend.devices[2]!.muted, "usb device muted after the unmute")
        XCTAssertFalse(backend.devices[3]!.muted, "built-in mic muted after the unmute")
    }

    /// Every mute records what it finds. Skipping it whenever the baseline merely
    /// happened to be non-empty left a device muted with nothing written down, which the
    /// next pass read back and recorded as the state the user had chosen.
    func testOurOwnMuteIsNeverRecordedAsTheUsersOwn() {
        let backend = FakeBackend([
            1: FakeDevice(uid: "BuiltInMicrophoneDevice", muteSettable: true,
                          hasWritableVolume: true),
        ])
        let engine = MuteEngine(backend: backend)

        engine.setMuted(true)
        backend.devices[2] = FakeDevice(uid: "AppleUSBAudioEngine:K30", muteSettable: true,
                                        hasWritableVolume: true)
        engine.setMuted(true)      // a revert, a watchdog, a second press

        XCTAssertEqual(engine.baseline["AppleUSBAudioEngine:K30"]?.muted, false,
                       "the headset was unmuted when we found it")

        engine.adoptNewDevices()
        engine.setMuted(false)
        XCTAssertFalse(backend.devices[2]!.muted)
    }

    /// The whole chain a user can perform by hand: mute, unplug, unmute, plug back in.
    /// It used to strand the device and then cement the mute on every later toggle.
    func testUnplugDuringMuteDoesNotCementTheMute() {
        let backend = FakeBackend([
            1: FakeDevice(uid: "BuiltInMicrophoneDevice", muteSettable: true,
                          hasWritableVolume: true),
            2: FakeDevice(uid: "AppleUSBAudioEngine:K30", muteSettable: true,
                          hasWritableVolume: true),
        ])
        let engine = MuteEngine(backend: backend)

        engine.setMuted(true)
        let headset = backend.devices.removeValue(forKey: 2)!
        engine.setMuted(false)
        backend.devices[2] = headset
        engine.adoptNewDevices()

        XCTAssertFalse(backend.devices[2]!.muted, "back on the desk and live")

        // And the cycle that used to cement it now just works.
        engine.setMuted(true)
        XCTAssertEqual(engine.baseline["AppleUSBAudioEngine:K30"]?.muted, false)
        engine.setMuted(false)
        XCTAssertFalse(backend.devices[2]!.muted)
    }
}

/// A backend whose property reads fail the first time, the way a Bluetooth device does
/// while it is still negotiating the HFP link.
private final class FlakyBackend: AudioBackend {
    var devices: [UInt32: FakeDevice] = [:]
    /// Device ids whose next `volume(of:)` must fail, once.
    var volumeReadFailsOnce: Set<UInt32> = []
    private(set) var guarded: Set<UInt32> = []

    init(_ devices: [UInt32: FakeDevice]) { self.devices = devices }

    func inputDevices() -> [AudioDeviceInfo] {
        devices.keys.sorted().map { id in
            let d = devices[id]!
            return AudioDeviceInfo(id: id, uid: d.uid, muteSettable: d.muteSettable,
                                   hasWritableVolume: d.hasWritableVolume)
        }
    }
    func mute(of id: UInt32) -> Bool? { devices[id]?.muted }
    func setMute(_ id: UInt32, _ muted: Bool) -> Bool {
        guard var d = devices[id], d.muteSettable else { return false }
        d.muted = muted; devices[id] = d; return true
    }
    func volume(of id: UInt32) -> Float? {
        if volumeReadFailsOnce.contains(id) { volumeReadFailsOnce.remove(id); return nil }
        return devices[id]?.volume
    }
    func setVolume(_ id: UInt32, _ volume: Float) -> Bool {
        guard var d = devices[id], d.hasWritableVolume else { return false }
        d.volume = volume; devices[id] = d; return true
    }
    func startVolumeGuard(_ id: UInt32) { guarded.insert(id) }
    func stopVolumeGuard(_ id: UInt32) { guarded.remove(id) }
    func isCapturing(_ id: UInt32) -> Bool { devices[id]?.capturing ?? false }
    func deferWork(_ work: @escaping () -> Void) { work() }
}

extension StrandedMuteTests {

    /// Headset off, mute, headset back on for the call.
    func testHeadsetConnectedWhileAlreadyMuted() {
        let backend = FakeBackend([
            1: FakeDevice(uid: "BuiltInMicrophoneDevice", muteSettable: true,
                          hasWritableVolume: true),
        ])
        let engine = MuteEngine(backend: backend)

        engine.setMuted(true)
        backend.devices[2] = FakeDevice(uid: "bt:input", muteSettable: true,
                                        hasWritableVolume: true, capturing: true)
        engine.adoptNewDevices()
        XCTAssertTrue(backend.devices[2]!.muted)

        engine.setMuted(false)
        XCTAssertFalse(backend.devices[2]!.muted, "headset must come back live")
        XCTAssertEqual(backend.devices[2]!.volume, 1.0)
    }

    /// The same sequence, but the headset fumbles one property read while HFP is still
    /// coming up. The level it had must survive that, because a baseline with no level
    /// in it leaves the device at zero: mute flag clear, Teams' own button working, and
    /// nobody able to hear a thing.
    func testHeadsetThatFumblesOneVolumeReadKeepsItsLevel() {
        let backend = FlakyBackend([
            1: FakeDevice(uid: "BuiltInMicrophoneDevice", muteSettable: true,
                          hasWritableVolume: true),
        ])
        let engine = MuteEngine(backend: backend)

        engine.setMuted(true)

        backend.devices[2] = FakeDevice(uid: "bt:input", muteSettable: false,
                                        hasWritableVolume: true, capturing: true, volume: 0.9)
        backend.volumeReadFailsOnce = [2]
        engine.adoptNewDevices()

        XCTAssertEqual(backend.devices[2]!.volume, 0, "muted by dropping the level")
        XCTAssertEqual(engine.baseline["bt:input"]?.volume, 0.9,
                       "the retry caught the level the first read missed")

        engine.setMuted(false)
        XCTAssertEqual(backend.devices[2]!.volume, 0.9, "restored to exactly what it was")
    }

    /// Last resort: a device sitting at zero with no level in its baseline at all must
    /// still come back audible rather than be left silent.
    func testDeviceAtZeroWithNoRecordedLevelIsBroughtBack() {
        let backend = FakeBackend([
            1: FakeDevice(uid: "bt:input", muteSettable: false, hasWritableVolume: true),
        ])
        let engine = MuteEngine(backend: backend)
        engine.restore(from: ["bt:input": MuteEngine.Baseline(muted: false, volume: nil)])
        XCTAssertEqual(backend.devices[1]!.volume, 1.0)
    }
}
