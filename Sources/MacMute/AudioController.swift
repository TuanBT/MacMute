import CoreAudio
import Foundation

/// Mutes the default input device through the CoreAudio HAL.
///
/// This is the fallback for everything that is not a Teams meeting (Zoom, Meet, Slack
/// huddles). Device capabilities are probed once when the default input changes, so a
/// keypress costs a single HAL round trip instead of enumerating every device.
final class AudioController {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var muteIsSettable = false
    private var volumeChannels: [UInt32] = []
    private var savedVolume: Float32 = 1.0

    init() {
        refreshDevice()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevice()
        }
    }

    private var hasDevice: Bool { deviceID != AudioDeviceID(kAudioObjectUnknown) }

    var isMuted: Bool {
        guard hasDevice else { return false }
        if muteIsSettable {
            var address = muteAddress()
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                return value != 0
            }
        }
        if let channel = volumeChannels.first, let volume = volume(channel: channel) {
            return volume <= 0.0001
        }
        return false
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard hasDevice else { return false }

        if muteIsSettable {
            var address = muteAddress()
            var value: UInt32 = muted ? 1 : 0
            return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                              UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        }

        guard !volumeChannels.isEmpty else { return false }
        if muted {
            // Remember where the level was so unmuting restores it rather than slamming to 100%.
            let current = volumeChannels.compactMap { volume(channel: $0) }.max() ?? 1.0
            savedVolume = current > 0.0001 ? current : 1.0
        }
        var target: Float32 = muted ? 0.0 : savedVolume
        var success = false
        for channel in volumeChannels {
            var address = volumeAddress(channel: channel)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &target) == noErr {
                success = true
            }
        }
        return success
    }

    // MARK: - Device discovery

    private func refreshDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr else { return }
        deviceID = device
        probeCapabilities()
    }

    /// Works out once whether this device supports a real hardware mute, and if not,
    /// which volume channels are writable.
    private func probeCapabilities() {
        muteIsSettable = false
        volumeChannels = []
        savedVolume = 1.0
        guard hasDevice else { return }

        var muteAddr = muteAddress()
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &muteAddr, &settable) == noErr,
               settable.boolValue {
                muteIsSettable = true
                return
            }
        }

        for channel: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = volumeAddress(channel: channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            volumeChannels.append(channel)
            // The master element covers every channel; no need to walk them individually.
            if channel == kAudioObjectPropertyElementMain { break }
        }
    }

    private func volume(channel: UInt32) -> Float32? {
        var address = volumeAddress(channel: channel)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func volumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: channel)
    }
}
