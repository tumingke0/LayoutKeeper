// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// DDC/CI packets (VESA MCCS over I2C, display address 0x37, host sub-address 0x51). Written from the public spec.
public enum DDCPacket {
    public static let brightness: UInt8=0x10
    /// 0.6.15: speaker volume and mute (1 = muted, 2 = not muted) are sent only to the monitor whose HDMI/DisplayPort
    /// audio is the current sound output and only when macOS can't change that output's volume (`VolumeKeyRouting`).
    public static let speakerVolume: UInt8=0x62
    public static let audioMute: UInt8=0x8D
    /// Input select (MCCS). Some LG monitors take input changes as VCP 0xF4 on host sub-address 0x50 instead.
    public static let inputSelect: UInt8=0x60
    public static let inputSelectAlt: UInt8=0xF4
    public static let defaultSubAddress: UInt8=0x51
    public static let altSubAddress: UInt8=0x50
    static func checksum(_ start: UInt8,_ bytes: [UInt8]) -> UInt8 { bytes.reduce(start,^) }
    /// "Get VCP feature" request body (sent to sub-address 0x51); checksum covers 0x6E ^ 0x51 ^ body.
    public static func getVCP(_ code: UInt8) -> [UInt8] { let b: [UInt8]=[0x82,0x01,code]; return b+[checksum(0x6E^defaultSubAddress,b)] }
    /// "Set VCP feature" body; the checksum starts from 0x6E ^ the sub-address the packet is written to.
    public static func setVCP(_ code: UInt8,_ value: UInt16,subAddress: UInt8=defaultSubAddress) -> [UInt8] {
        let b: [UInt8]=[0x84,0x03,code,UInt8(value>>8),UInt8(value & 0xFF)]; return b+[checksum(0x6E^subAddress,b)]
    }
    /// Parses a "VCP feature reply" (as read back from 0x51): 6E 88 02 rc code type maxH maxL curH curL chk.
    public static func parseReply(_ r: [UInt8],code: UInt8) -> (current: Int,max: Int)? {
        guard r.count>=11,r[2]==0x02,r[3]==0x00,r[4]==code else { return nil }
        guard checksum(0x50,Array(r[0..<10]))==r[10] else { return nil }
        let mx=Int(r[6])<<8|Int(r[7]),cur=Int(r[8])<<8|Int(r[9])
        guard mx>0 else { return nil }
        return (cur,mx)
    }
}

public enum BrightnessStep {
    /// Brightness keys move 5% per press; volume keys keep 3%. ⌥⇧ fine-tunes both by 1%.
    public static let coarse=0.05, volumeCoarse=0.03, fine=0.01
    /// Next level, snapped to the step grid.
    public static func next(_ v: Double,up: Bool,fine isFine: Bool=false,coarse c: Double=coarse) -> Double {
        let s=isFine ? fine : c
        let idx=(v/s).rounded(); let snapped=idx*s
        var n: Double
        if abs(snapped-v)<1e-6 { n=snapped+(up ? s : -s) } else { n=up ? (v/s).rounded(.up)*s : (v/s).rounded(.down)*s }
        n=min(1,max(0,n))
        return (n*1e6).rounded()/1e6
    }
    public static func toDDC(_ v: Double,max m: Int) -> UInt16 { UInt16(Swift.min(Double(m),Swift.max(0,(v*Double(m)).rounded()))) }
    public static func fromDDC(_ cur: Int,max m: Int) -> Double { m>0 ? Swift.min(1,Swift.max(0,Double(cur)/Double(m))) : 0 }
}

/// Rate limit for DDC writes: at most one write per `minInterval`; intermediate values are coalesced (latest wins).
public struct WriteLimiter {
    public var minInterval: TimeInterval
    public private(set) var lastWrite: Date?
    public init(minInterval: TimeInterval=0.06) { self.minInterval=minInterval }
    public func delay(now: Date) -> TimeInterval { lastWrite.map{ max(0,minInterval-now.timeIntervalSince($0)) } ?? 0 }
    public mutating func didWrite(at now: Date) { lastWrite=now }
}

/// Key takeover is on by default but yields while another display utility that grabs the same keys is running.
public enum KeyTakeover {
    public static let conflictingApps: [String:String]=[
        "pro.betterdisplay.BetterDisplay":"BetterDisplay",
        "me.guillaumeb.MonitorControl":"MonitorControl",
        "fyi.lunar.Lunar":"Lunar",
    ]
    public static func conflicts(running: [String]) -> [String] { running.compactMap{ conflictingApps[$0] }.sorted() }
    public static func active(enabled: Bool,running: [String]) -> Bool { enabled && conflicts(running:running).isEmpty }
}

/// NX_SYSDEFINED media keys (subtype 8): data1 = keyCode<<16 | state<<8.
public enum MediaKey: Equatable {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute
    public static func decode(data1: Int) -> (key: MediaKey,down: Bool)? {
        let code=(data1 & 0xFFFF0000)>>16, state=(data1 & 0xFF00)>>8
        let key: MediaKey
        switch code { case 2: key = .brightnessUp; case 3: key = .brightnessDown; case 0: key = .volumeUp; case 1: key = .volumeDown; case 7: key = .mute; default: return nil }
        return (key,state==0x0A)
    }
    /// Apple keyboards may also send brightness as ordinary key codes (kVK 144 / 145).
    public static func fromKeyCode(_ code: Int) -> MediaKey? { code==144 ? .brightnessUp : (code==145 ? .brightnessDown : nil) }
    public var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
}

/// 0.6.9: what a volume/mute key does. Always the current sound output (the default output device), whichever screen
/// the mouse is on. The app takes the key (3% steps, ⌥⇧ 1%) only when it is enabled and the device has a settable
/// volume; otherwise the key goes to macOS untouched.
/// 0.6.15: when the output is a monitor's HDMI/DisplayPort audio whose volume macOS can't set, and that monitor was
/// matched (`MonitorAudioMatcher`), all three keys go to the monitor's speakers over DDC instead.
public enum VolumeKeyRouting: Equatable {
    case systemOutput, passThrough
    case monitorSpeaker(UInt32)
    public static func route(_ key: MediaKey,enabled: Bool,outputVolumeSettable: Bool,outputMuteSettable: Bool) -> VolumeKeyRouting {
        guard !key.isBrightness,enabled else { return .passThrough }
        if key == .mute { return outputMuteSettable ? .systemOutput : .passThrough }
        return outputVolumeSettable ? .systemOutput : .passThrough
    }
    /// `speakerDisplay`: the monitor the output was matched to (nil when none). A settable output always stays on the
    /// system volume, so one key press never changes two volumes.
    public static func route(_ key: MediaKey,enabled: Bool,outputVolumeSettable: Bool,outputMuteSettable: Bool,
                             monitorSpeakerEnabled: Bool,speakerDisplay: UInt32?) -> VolumeKeyRouting {
        guard !key.isBrightness,enabled else { return .passThrough }
        if !outputVolumeSettable,monitorSpeakerEnabled,let id=speakerDisplay { return .monitorSpeaker(id) }
        return route(key,enabled:enabled,outputVolumeSettable:outputVolumeSettable,outputMuteSettable:outputMuteSettable)
    }
}

public enum DisplayControlPrefs {
    public static let showInMenu="displayControl.showInMenu"
    public static let brightnessKeys="displayControl.brightnessKeys"
    public static let volumeKeys="displayControl.volumeKeys"
    public static let softwareFallback="displayControl.softwareFallback"
    public static let ddcDisabled="displayControl.ddcDisabled"
    public static let syncWithBuiltIn="displayControl.syncWithBuiltIn"
    /// 0.6.15
    public static let monitorSpeakerKeys="displayControl.monitorSpeakerKeys"
    public static let inputMenu="displayControl.inputMenu"
    /// JSON `[displayKey: [InputSource]]`; a display without an entry uses `InputSourceCatalog.defaults`.
    public static let inputSources="displayControl.inputSources"
    /// Display keys whose first-switch confirmation was turned off ("不再提醒").
    public static let inputConfirmed="displayControl.inputConfirmed"
    /// `[displayKey: CoreAudio output device name]` chosen by hand; no entry = automatic.
    public static let audioDeviceOverrides="displayControl.audioDeviceOverrides"
}

/// Propagates built-in display brightness changes (ambient light or user adjustments) as an equal delta to external monitors,
/// preserving each external monitor's relative brightness offset.
public enum BuiltInBrightnessSync {
    public static let threshold: Double = 0.02
    public static let minExternalDelta: Double = 0.005

    /// Evaluates whether a built-in brightness reading should propagate a delta to external displays.
    /// - Parameters:
    ///   - enabled: Whether `syncWithBuiltIn` is turned on.
    ///   - clamshell: Whether the MacBook lid is closed (`AppleClamshellState`).
    ///   - previousBuiltIn: The last synced built-in brightness (0...1), or `nil` if not yet established.
    ///   - currentBuiltIn: The newly read built-in brightness (0...1), or `nil` if no active built-in display.
    ///   - externalBrightnesses: Current brightness (0...1) for each external display ID.
    /// - Returns: Updated `baseline` for built-in brightness, and the list of `(id, newBrightness)` updates for external displays whose target changed by at least `0.005`.
    public static func evaluate(
        enabled: Bool,
        clamshell: Bool,
        previousBuiltIn: Double?,
        currentBuiltIn: Double?,
        externalBrightnesses: [(id: UInt32, brightness: Double)]
    ) -> (baseline: Double?, updates: [(id: UInt32, newBrightness: Double)]) {
        guard enabled, !clamshell, let rawCurrent = currentBuiltIn else {
            return (baseline: nil, updates: [])
        }
        let clampedCurrent = min(1, max(0, (rawCurrent * 1e6).rounded() / 1e6))
        guard let rawPrevious = previousBuiltIn else {
            return (baseline: clampedCurrent, updates: [])
        }
        let clampedPrevious = min(1, max(0, (rawPrevious * 1e6).rounded() / 1e6))
        let delta = clampedCurrent - clampedPrevious
        guard abs(delta) + 1e-9 >= threshold else {
            return (baseline: clampedPrevious, updates: [])
        }
        var updates: [(id: UInt32, newBrightness: Double)] = []
        for ext in externalBrightnesses {
            let curExt = min(1, max(0, ext.brightness))
            let target = min(1, max(0, ((curExt + delta) * 1e6).rounded() / 1e6))
            if abs(target - curExt) + 1e-9 >= minExternalDelta {
                updates.append((id: ext.id, newBrightness: target))
            }
        }
        return (baseline: clampedCurrent, updates: updates)
    }
}
