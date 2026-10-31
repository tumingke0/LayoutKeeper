// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// 0.6.15: finds the external monitor whose speakers play the current sound output. Only HDMI/DisplayPort outputs whose
/// volume macOS can't set qualify; any doubt returns nil and the key goes to macOS as before.
/// Name matching follows the idea MonitorControl uses (audio device name ≈ display name).
public enum MonitorAudioMatcher {
    /// CoreAudio `kAudioDeviceTransportTypeHDMI` ('hdmi') and `kAudioDeviceTransportTypeDisplayPort` ('dprt').
    public static let transportHDMI: UInt32=0x68646D69
    public static let transportDisplayPort: UInt32=0x64707274
    public static func isDisplayTransport(_ t: UInt32) -> Bool { t == transportHDMI || t == transportDisplayPort }

    public struct Candidate: Equatable {
        public var id: UInt32
        public var name: String
        /// VCP 0x62 was read back from this monitor.
        public var hasSpeakerVolume: Bool
        /// Output device name chosen by hand in settings (nil = automatic).
        public var overrideDevice: String?
        public init(id: UInt32,name: String,hasSpeakerVolume: Bool,overrideDevice: String?=nil) {
            self.id=id; self.name=name; self.hasSpeakerVolume=hasSpeakerVolume; self.overrideDevice=overrideDevice
        }
    }

    /// Case-insensitive, letters and digits only, and a trailing " (2)" style suffix removed.
    public static func normalized(_ s: String) -> String {
        var t=s.trimmingCharacters(in:.whitespacesAndNewlines)
        if let r=t.range(of:"\\s*\\(\\d+\\)$",options:.regularExpression) { t.removeSubrange(r) }
        return String(t.lowercased().unicodeScalars.filter{ CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// - `candidates`: every external DDC monitor whose DDC channel is known for certain.
    /// - `externalCount`: all external displays (DDC or not); the "only one monitor" fallback needs exactly one.
    public static func match(deviceName: String,transport: UInt32,volumeSettable: Bool,candidates: [Candidate],externalCount: Int) -> UInt32? {
        guard !volumeSettable,isDisplayTransport(transport) else { return nil }
        let device=deviceName.trimmingCharacters(in:.whitespacesAndNewlines)
        // 1. Chosen by hand.
        let manual=candidates.filter{ $0.overrideDevice.map{ $0.trimmingCharacters(in:.whitespacesAndNewlines) == device } ?? false }
        if manual.count == 1 { return manual[0].id }
        if manual.count > 1 { return nil }
        // Monitors assigned to another device by hand are out of automatic matching.
        let auto=candidates.filter{ $0.overrideDevice == nil && $0.hasSpeakerVolume }
        // 2. Same name.
        let key=normalized(device)
        if !key.isEmpty {
            let byName=auto.filter{ normalized($0.name) == key }
            if byName.count == 1 { return byName[0].id }
            if byName.count > 1 { return nil }
        }
        // 3. One external monitor in total, and it has speaker volume.
        if externalCount == 1,candidates.count == 1,auto.count == 1 { return auto[0].id }
        return nil
    }
}

/// Speaker level of one monitor as LayoutKeeper tracks it. Soft mute (monitor without VCP 0x8D) writes volume 0 and
/// keeps `level`, so unmuting restores it.
public struct SpeakerLevel: Equatable {
    /// Start level when the monitor's volume can't be read: low, so the first press is never loud.
    public static let unknownStart=0.10
    public var level: Double
    public var muted: Bool
    public init(level: Double,muted: Bool=false) { self.level=min(1,max(0,level)); self.muted=muted }

    public enum Write: Equatable { case volume(Double), mute(Bool) }

    /// One key press. `hardwareMute`: the monitor answers VCP 0x8D.
    /// Like macOS: a volume key while muted unmutes and then steps from the kept level.
    public func press(_ key: MediaKey,fine: Bool,hardwareMute: Bool) -> (SpeakerLevel,[Write]) {
        var next=self
        switch key {
        case .mute:
            next.muted.toggle()
            if hardwareMute { return (next,[.mute(next.muted)]) }
            return (next,[.volume(next.muted ? 0 : level)])
        case .volumeUp, .volumeDown:
            let v=BrightnessStep.next(level,up:key == .volumeUp,fine:fine,coarse:BrightnessStep.volumeCoarse)
            next.level=v; next.muted=false
            var writes: [Write]=[]
            if muted && hardwareMute { writes.append(.mute(false)) }
            writes.append(.volume(v))
            return (next,writes)
        case .brightnessUp, .brightnessDown:
            return (self,[])
        }
    }

    /// Merges a fresh DDC read into the tracked state. While soft-muted the monitor reads 0, which must not replace
    /// the kept level.
    public static func merged(existing: SpeakerLevel?,readLevel: Double,readMuted: Bool?,hardwareMute: Bool) -> SpeakerLevel {
        if let e=existing,e.muted,!hardwareMute { return e }
        return SpeakerLevel(level:readLevel,muted:hardwareMute ? (readMuted ?? false) : false)
    }
}
