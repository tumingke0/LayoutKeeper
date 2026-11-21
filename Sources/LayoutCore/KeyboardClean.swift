// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// 「清理键盘」: lock the keyboard for a short while so it can be wiped. Pure logic here (unit tested); the event tap
/// and the overlay live in SpacePort/KeyboardCleaner.swift.
public enum KeyboardCleanDuration: Int, CaseIterable, Codable, Sendable {
    case seconds30=30, minute1=60, minutes2=120, minutes5=300
    public static let defaultDuration=KeyboardCleanDuration.minute1
    /// Hard limit for any session, whatever is stored.
    public static let maxSeconds: TimeInterval=300
    public var seconds: TimeInterval { TimeInterval(rawValue) }
    public var title: String {
        switch self {
        case .seconds30: return lk("30 秒")
        case .minute1: return lk("1 分钟")
        case .minutes2: return lk("2 分钟")
        case .minutes5: return lk("5 分钟")
        }
    }
}

public struct KeyboardCleanSettings: Codable, Equatable, Sendable {
    public var duration: KeyboardCleanDuration
    /// Also drop mouse / trackpad clicks, drags, scrolling and gestures (the pointer still moves).
    public var blockPointer: Bool
    public static let defaults=KeyboardCleanSettings(duration:.defaultDuration,blockPointer:false)
    public init(duration: KeyboardCleanDuration,blockPointer: Bool) { self.duration=duration; self.blockPointer=blockPointer }
    enum CodingKeys: String, CodingKey { case duration, blockPointer }
    /// Missing or unknown values fall back to the defaults (older or hand-edited preferences never fail to load).
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        duration=(try? c.decodeIfPresent(KeyboardCleanDuration.self,forKey:.duration)) ?? .defaultDuration
        blockPointer=(try? c.decodeIfPresent(Bool.self,forKey:.blockPointer)) ?? false
    }
    public static let preferenceKey="keyboardClean"
}

public enum KeyboardCleanVerdict: Equatable, Sendable {
    case pass, drop, dropCounted, escapeDown, escapeUp
    public var drops: Bool { self != .pass }
}

/// What the lock tap does with each event. `type` is the raw CGEventType / NSEvent type number.
public enum KeyboardCleanFilter {
    public static let keyDown: UInt32=10, keyUp: UInt32=11, flagsChanged: UInt32=12
    /// NX_SYSDEFINED; subtype 8 carries the media keys (volume, brightness, playback, keyboard backlight, Touch Bar).
    public static let systemDefined: UInt32=14
    public static let mediaKeySubtype=8
    public static let escapeKeyCode=53
    /// Mouse / trackpad events dropped only when `blockPointer` is on: buttons, drags, scroll, gestures
    /// (rotate 18, begin/end 19/20, gesture 29, magnify 30, swipe 31, smart magnify 32, pressure 34).
    /// Pointer movement (5) is never in this list.
    public static let pointerTypes: [UInt32]=[1,2,3,4,6,7,22,25,26,27,18,19,20,29,30,31,32,34]
    public static let mouseMoved: UInt32=5
    public static func keyboardTypes() -> [UInt32] { [keyDown,keyUp,flagsChanged,systemDefined] }
    /// Event types the tap has to listen to.
    public static func tapTypes(blockPointer: Bool) -> [UInt32] { keyboardTypes()+(blockPointer ? pointerTypes : []) }
    /// - Parameters:
    ///   - autorepeat: a held key repeating (dropped, not counted).
    ///   - mediaKeyDown: for type 14 subtype 8, whether this is the press (the release is dropped, not counted).
    public static func verdict(type: UInt32,subtype: Int = 0,keyCode: Int = 0,autorepeat: Bool = false,mediaKeyDown: Bool = true,blockPointer: Bool) -> KeyboardCleanVerdict {
        switch type {
        case keyDown:
            if keyCode == escapeKeyCode { return .escapeDown }
            return autorepeat ? .drop : .dropCounted
        case keyUp:
            return keyCode == escapeKeyCode ? .escapeUp : .drop
        case flagsChanged:
            return .drop
        case systemDefined:
            guard subtype == mediaKeySubtype else { return .pass }
            return mediaKeyDown && !autorepeat ? .dropCounted : .drop
        case mouseMoved:
            return .pass
        default:
            return blockPointer && pointerTypes.contains(type) ? .drop : .pass
        }
    }
    /// flagsChanged fires on press and release; a press is when a modifier bit is added (counted once).
    public static func isModifierPress(old: UInt64,new: UInt64) -> Bool {
        let mask: UInt64=0x00FF_0000  // Caps Lock, Shift, Control, Option, Command, Num pad, Help, Fn
        return (new & mask) & ~(old & mask) != 0
    }
    /// NX_SYSDEFINED data1 of a media key: key state 0x0A is down, 0x0B is up; bit 0 is the repeat flag.
    public static func mediaKeyState(data1: Int) -> (down: Bool,repeating: Bool) {
        let flags=data1 & 0xFFFF
        return (((flags & 0xFF00) >> 8) == 0x0A,(flags & 0x1) == 1)
    }
}

/// Hold Esc for 3 seconds to unlock. Another key (or letting go) starts over.
public struct EscapeHold: Equatable, Sendable {
    public static let required: TimeInterval=3
    public private(set) var startedAt: Date?
    public init() {}
    /// Repeats while held only keep the original start.
    public mutating func escapeDown(at now: Date) { if startedAt == nil { startedAt=now } }
    public mutating func escapeUp() { startedAt=nil }
    public mutating func otherKey() { startedAt=nil }
    public func progress(at now: Date) -> Double {
        guard let startedAt else { return 0 }
        return min(1,max(0,now.timeIntervalSince(startedAt)/Self.required))
    }
    public func isComplete(at now: Date) -> Bool { progress(at:now) >= 1 }
}

public enum KeyboardCleanEndReason: String, Equatable, Sendable {
    /// 「完成」, time is up, Esc held, macOS turned the tap off, LayoutKeeper quit.
    case done, timeout, escape, tapLost, quit
    /// Unlocked before the user meant to: tell them.
    public var needsNotice: Bool { self == .tapLost }
}

/// One lock. Uses an absolute end time, so after sleep the lock ends as soon as the Mac wakes past it.
public struct KeyboardCleanSession: Equatable, Sendable {
    public let startedAt: Date
    public let endsAt: Date
    public let blockPointer: Bool
    public init(start: Date,duration: TimeInterval,blockPointer: Bool) {
        startedAt=start
        endsAt=start.addingTimeInterval(min(KeyboardCleanDuration.maxSeconds,max(1,duration)))
        self.blockPointer=blockPointer
    }
    public init(start: Date,settings: KeyboardCleanSettings) { self.init(start:start,duration:settings.duration.seconds,blockPointer:settings.blockPointer) }
    public func remaining(at now: Date) -> TimeInterval { max(0,endsAt.timeIntervalSince(now)) }
    /// Also true when the clock went backwards past the start (never lock longer than the limit).
    public func isExpired(at now: Date) -> Bool {
        now >= endsAt || endsAt.timeIntervalSince(now) > KeyboardCleanDuration.maxSeconds+1
    }
    /// "1:00", "0:09": whole seconds, rounded up.
    public static func countdownText(_ remaining: TimeInterval) -> String {
        let total=Int(max(0,remaining).rounded(.up))
        return String(format:"%d:%02d",total/60,total%60)
    }
}
