// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import CoreAudio
import AudioToolbox

/// The Mac's system output volume: the current default output device (built-in speakers, headphones, a USB or
/// Bluetooth device, or a monitor's HDMI/DisplayPort audio as macOS exposes it). Uses the same virtual main volume
/// and mute macOS's own volume keys change, so the menu-bar volume stays in sync. No DDC is involved.
public enum SystemVolume {
    public struct Output: Equatable { public var device: AudioObjectID; public var name: String; public var volumeSettable: Bool; public var muteSettable: Bool }
    private static func address(_ selector: AudioObjectPropertySelector,_ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    public static func defaultOutput() -> Output? {
        var device=AudioObjectID(kAudioObjectUnknown), size=UInt32(MemoryLayout<AudioObjectID>.size)
        var a=address(kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&device)==noErr,device != kAudioObjectUnknown else { return nil }
        return Output(device:device,name:name(device) ?? "",volumeSettable:settable(device,kAudioHardwareServiceDeviceProperty_VirtualMainVolume),muteSettable:settable(device,kAudioDevicePropertyMute))
    }
    static func settable(_ device: AudioObjectID,_ selector: AudioObjectPropertySelector) -> Bool {
        var a=address(selector)
        guard AudioObjectHasProperty(device,&a) else { return false }
        var ok: DarwinBoolean=false
        return AudioObjectIsPropertySettable(device,&a,&ok)==noErr && ok.boolValue
    }
    static func name(_ device: AudioObjectID) -> String? {
        var a=address(kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?, size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device,&a,0,nil,&size,&value)==noErr,let value else { return nil }
        return value.takeRetainedValue() as String
    }
    public static func volume(_ device: AudioObjectID) -> Double? {
        var a=address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v=Float32(0), size=UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device,&a,0,nil,&size,&v)==noErr else { return nil }
        return Double(v)
    }
    @discardableResult public static func setVolume(_ device: AudioObjectID,_ value: Double) -> Bool {
        var a=address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v=Float32(min(1,max(0,value)))
        return AudioObjectSetPropertyData(device,&a,0,nil,UInt32(MemoryLayout<Float32>.size),&v)==noErr
    }
    public static func muted(_ device: AudioObjectID) -> Bool? {
        var a=address(kAudioDevicePropertyMute)
        var v=UInt32(0), size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device,&a),AudioObjectGetPropertyData(device,&a,0,nil,&size,&v)==noErr else { return nil }
        return v != 0
    }
    @discardableResult public static func setMuted(_ device: AudioObjectID,_ on: Bool) -> Bool {
        var a=address(kAudioDevicePropertyMute)
        var v=UInt32(on ? 1 : 0)
        guard AudioObjectHasProperty(device,&a) else { return false }
        return AudioObjectSetPropertyData(device,&a,0,nil,UInt32(MemoryLayout<UInt32>.size),&v)==noErr
    }
}
