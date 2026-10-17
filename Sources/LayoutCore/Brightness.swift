// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// DDC/CI packets (VESA MCCS over I2C, display address 0x37, host sub-address 0x51). Written from the public spec.
public enum DDCPacket {
    public static let brightness: UInt8=0x10, volume: UInt8=0x62, mute: UInt8=0x8D
    static func checksum(_ start: UInt8,_ bytes: [UInt8]) -> UInt8 { bytes.reduce(start,^) }
    /// "Get VCP feature" request body (sent to sub-address 0x51); checksum covers 0x6E ^ 0x51 ^ body.
    public static func getVCP(_ code: UInt8) -> [UInt8] { let b: [UInt8]=[0x82,0x01,code]; return b+[checksum(0x6E^0x51,b)] }
    public static func setVCP(_ code: UInt8,_ value: UInt16) -> [UInt8] {
        let b: [UInt8]=[0x84,0x03,code,UInt8(value>>8),UInt8(value & 0xFF)]; return b+[checksum(0x6E^0x51,b)]
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

public enum DisplayControlPrefs {
    public static let showInMenu="displayControl.showInMenu"
    public static let brightnessKeys="displayControl.brightnessKeys"
    public static let volumeKeys="displayControl.volumeKeys"
    public static let softwareFallback="displayControl.softwareFallback"
    public static let ddcDisabled="displayControl.ddcDisabled"
}
