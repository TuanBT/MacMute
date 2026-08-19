import XCTest
@testable import MacMuteCore

/// A device that can be told to lie the way real ones do.
private struct FakeDevice {
    var uid: String
    var muteSettable: Bool
    var hasWritableVolume: Bool
    var muted = false
    var volume: Float? = 1.0
    /// Accepts the write, reports success, changes nothing — the virtual
    /// "Microsoft Teams Audio" device behaves exactly like this.
    var ignoresWrites = false
}

private final class FakeBackend: AudioBackend {
    var devices: [UInt32: FakeDevice] = [:]
    private(set) var guarded: Set<UInt32> = []
    private(set) var setVolumeCalls = 0

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
        if !device.ignoresWrites { device.muted = muted }
        devices[id] = device
        return true   // noErr, whether or not anything changed
    }

    func volume(of id: UInt32) -> Float? { devices[id]?.volume }

    func setVolume(_ id: UInt32, _ volume: Float) -> Bool {
        setVolumeCalls += 1
        guard var device = devices[id], device.hasWritableVolume else { return false }
        if !device.ignoresWrites { device.volume = volume }
        devices[id] = device
        return true
    }

    func startVolumeGuard(_ id: UInt32) { guarded.insert(id) }
    func stopVolumeGuard(_ id: UInt32) { guarded.remove(id) }
}

final class MuteEngineTests: XCTestCase {

    private func engine(_ devices: [UInt32: FakeDevice]) -> (MuteEngine, FakeBackend) {
        let backend = FakeBackend(devices)
        return (MuteEngine(backend: backend), backend)
    }

    // MARK: - Every device, not just the default

    func testMutesEveryInputDevice() {
        let (engine, backend) = engine([
            1: FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true),
            2: FakeDevice(uid: "usb", muteSettable: true, hasWritableVolume: true),
        ])
        XCTAssertTrue(engine.setMuted(true))
        XCTAssertTrue(backend.devices[1]!.muted)
        XCTAssertTrue(backend.devices[2]!.muted)
    }

    // MARK: - Devices that lie

    func testDeviceThatIgnoresWritesIsNeverGuarded() {
        // The regression that mattered: a device reporting success while changing
        // nothing used to get a volume guard, which then rewrote it forever.
        let (engine, backend) = engine([
            1: FakeDevice(uid: "virtual", muteSettable: true, hasWritableVolume: true,
                          ignoresWrites: true),
        ])
        XCTAssertFalse(engine.setMuted(true), "a device that changes nothing is not muted")
        XCTAssertTrue(backend.guarded.isEmpty, "guarding it would spin against coreaudiod")
        XCTAssertTrue(engine.deafDevices.contains("virtual"))
    }

    func testDeafDeviceIsSkippedOnLaterToggles() {
        let (engine, backend) = engine([
            1: FakeDevice(uid: "virtual", muteSettable: true, hasWritableVolume: true,
                          ignoresWrites: true),
        ])
        engine.setMuted(true)
        engine.setMuted(false)
        let before = backend.setVolumeCalls
        engine.setMuted(true)
        XCTAssertEqual(backend.setVolumeCalls, before, "known-deaf device must not be retried")
    }

    func testOneGoodDeviceIsEnoughToReportSuccess() {
        let (engine, _) = engine([
            1: FakeDevice(uid: "virtual", muteSettable: true, hasWritableVolume: true,
                          ignoresWrites: true),
            2: FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true),
        ])
        XCTAssertTrue(engine.setMuted(true))
    }

    // MARK: - Volume fallback

    func testFallsBackToVolumeWhenMuteIsUnavailable() {
        let (engine, backend) = engine([
            1: FakeDevice(uid: "usb", muteSettable: false, hasWritableVolume: true),
        ])
        XCTAssertTrue(engine.setMuted(true))
        XCTAssertEqual(backend.devices[1]!.volume, 0)
        XCTAssertTrue(backend.guarded.contains(1), "an honoured write is worth guarding")
    }

    func testVolumeFallbackRestoresTheOriginalLevel() {
        var device = FakeDevice(uid: "usb", muteSettable: false, hasWritableVolume: true)
        device.volume = 0.42
        let (engine, backend) = engine([1: device])
        engine.setMuted(true)
        engine.setMuted(false)
        XCTAssertEqual(backend.devices[1]!.volume, 0.42, "unmute must not slam the level to 1.0")
        XCTAssertTrue(backend.guarded.isEmpty)
    }

    func testDeviceWithNeitherMuteNorVolumeFails() {
        let (engine, _) = engine([
            1: FakeDevice(uid: "dumb", muteSettable: false, hasWritableVolume: false),
        ])
        XCTAssertFalse(engine.setMuted(true))
    }

    // MARK: - Restoring what the user had

    func testUnmuteLeavesAPreExistingMuteAlone() {
        var device = FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true)
        device.muted = true   // the user muted it themselves before MacMute ran
        let (engine, backend) = engine([1: device])
        engine.setMuted(true)
        engine.setMuted(false)
        XCTAssertTrue(backend.devices[1]!.muted, "MacMute must not unmute what it did not mute")
    }

    func testSecondMuteDoesNotOverwriteTheBaseline() {
        let (engine, backend) = engine([
            1: FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true),
        ])
        engine.setMuted(true)
        engine.setMuted(true)   // e.g. a device arriving re-triggers a mute
        engine.setMuted(false)
        XCTAssertFalse(backend.devices[1]!.muted, "the baseline recorded our own mute")
    }

    // MARK: - Hot plug and crash recovery

    func testDeviceArrivingWhileMutedIsMutedToo() {
        let (engine, backend) = engine([
            1: FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true),
        ])
        engine.setMuted(true)
        backend.devices[2] = FakeDevice(uid: "headset", muteSettable: true,
                                        hasWritableVolume: true)
        engine.adoptNewDevices()
        XCTAssertTrue(backend.devices[2]!.muted, "a live mic the user believes is off")
    }

    func testRestoreFromDiskUndoesAMuteLeftByACrash() {
        var device = FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true)
        device.muted = true      // left behind by the killed process
        device.volume = 0
        let (engine, backend) = engine([1: device])

        engine.restore(from: ["built-in": MuteEngine.Baseline(muted: false, volume: 0.88)])

        XCTAssertFalse(engine.isMuted)
        XCTAssertFalse(backend.devices[1]!.muted)
        XCTAssertEqual(backend.devices[1]!.volume, 0.88)
        XCTAssertTrue(engine.baseline.isEmpty)
    }

    func testBaselineIsPublishedForPersistence() {
        var published: [String: MuteEngine.Baseline] = [:]
        let (engine, _) = engine([
            1: FakeDevice(uid: "built-in", muteSettable: true, hasWritableVolume: true),
        ])
        engine.onBaselineChange = { published = $0 }
        engine.setMuted(true)
        XCTAssertEqual(published.count, 1, "a crash right now must be recoverable")
        engine.setMuted(false)
        XCTAssertTrue(published.isEmpty)
    }
}
