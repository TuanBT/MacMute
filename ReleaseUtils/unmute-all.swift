#!/usr/bin/env swift
//
// Rescue tool: clears the mute and restores full input volume on every input device.
//
//   swift ReleaseUtils/unmute-all.swift
//
// A HAL mute outlives the process that set it, and macOS shows nothing to explain a
// microphone that has been silenced this way. MacMute restores its own mutes on quit,
// on SIGTERM/SIGINT and on the next launch after a crash — this is for the case where
// something went wrong anyway, or where another app left a device muted.
//
import CoreAudio
import Foundation
func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope, _ e: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: e)
}
func nm(_ id: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
    var cf: Unmanaged<CFString>? = nil; var sz = UInt32(MemoryLayout<CFTypeRef?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &cf) == noErr, let cf else { return "?" }
    return cf.takeRetainedValue() as String
}
var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioDeviceID](repeating: 0, count: Int(size)/MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
for id in ids {
    var sa = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var ssz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ssz) == noErr, ssz > 0 else { continue }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(ssz), alignment: 16); defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &sa, 0, nil, &ssz, buf) == noErr else { continue }
    let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
    var ch: UInt32 = 0
    withUnsafePointer(to: &abl.pointee.mBuffers) { p in
        for b in UnsafeBufferPointer(start: p, count: Int(abl.pointee.mNumberBuffers)) { ch += b.mNumberChannels }
    }
    guard ch > 0 else { continue }
    var ma = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
    var off: UInt32 = 0
    AudioObjectSetPropertyData(id, &ma, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
    var va = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
    var vol: Float32 = 1.0
    if AudioObjectHasProperty(id, &va) {
        AudioObjectSetPropertyData(id, &va, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
    }
    print("  \(nm(id)): mute=off, volume=1.00")
}
