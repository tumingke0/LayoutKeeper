// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// Per-monitor choices, keyed by MonitorIdentity.key. Stored in preferences, never in layout files.
public struct MonitorPreference: Codable, Equatable {
    public var restore: AutoRestoreMode?
    public var displayName: String?
    /// The monitor's own name when the choice was made, so Settings can list screens that aren't connected.
    public var seenName: String?
    public init(restore: AutoRestoreMode? = nil, displayName: String? = nil, seenName: String? = nil) { self.restore=restore; self.displayName=displayName; self.seenName=seenName }
    public var label: String { displayName ?? seenName ?? lk("外接屏") }
}
public struct MonitorPreferences: Codable, Equatable {
    public var entries: [String:MonitorPreference]=[:]
    public init(entries: [String:MonitorPreference] = [:]) { self.entries=entries }
    public func displayName(_ identity: MonitorIdentity) -> String {
        let custom=entries[identity.key]?.displayName?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? identity.name : custom
    }
    public func restore(_ key: String) -> AutoRestoreMode? { entries[key]?.restore }
    public mutating func setDisplayName(_ name: String?,for key: String,seenName: String? = nil) {
        let trimmed=name?.trimmingCharacters(in:.whitespacesAndNewlines)
        update(key) { $0.displayName=(trimmed?.isEmpty ?? true) ? nil : String(trimmed!.prefix(40)); if let seenName { $0.seenName=seenName } }
    }
    public mutating func setRestore(_ mode: AutoRestoreMode?,for key: String,seenName: String? = nil) { update(key) { $0.restore=mode; if let seenName { $0.seenName=seenName } } }
    private mutating func update(_ key: String,_ change: (inout MonitorPreference) -> Void) {
        var entry=entries[key] ?? MonitorPreference()
        change(&entry)
        entries[key]=(entry.restore == nil && entry.displayName == nil) ? nil : entry
    }
}

public enum ReconnectAction: Equatable { case none, paused, askOnce, ask, auto }
public enum AskOnceAnswer: Equatable { case automatic, askEachTime, never
    public var mode: AutoRestoreMode {
        switch self { case .automatic: return .auto; case .askEachTime: return .ask; case .never: return .off }
    }
}

/// "Ask once, then automatic": with the default global mode (先询问) and no remembered choice for this monitor,
/// the first reconnect asks once; the answer is remembered per monitor and overrides the global default.
/// A global 自动/关闭 is an explicit choice and is applied without asking. Pause suppresses everything.
public enum ReconnectPolicy {
    public static func action(global: AutoRestoreMode,perMonitor: AutoRestoreMode?,pausedUntil: Date?,now: Date) -> ReconnectAction {
        if let pausedUntil,now<pausedUntil { return .paused }
        if let perMonitor {
            switch perMonitor { case .off: return .none; case .ask: return .ask; case .auto: return .auto }
        }
        switch global { case .off: return .none; case .auto: return .auto; case .ask: return .askOnce }
    }
}

public enum AutoRestorePause: String, CaseIterable {
    case oneHour, untilTomorrow
    public var title: String { self == .oneHour ? lk("1 小时") : lk("直到明天") }
    public func until(from now: Date,calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .untilTomorrow: return calendar.startOfDay(for:calendar.date(byAdding:.day,value:1,to:now) ?? now.addingTimeInterval(86400))
        }
    }
}

public enum RelativeTime {
    /// "今天 09:42" / "昨天 09:42" / "10月9日 09:42".
    public static func short(_ date: Date,now: Date = Date(),calendar: Calendar = .current) -> String {
        let f=DateFormatter(); f.locale=Locale(identifier:Localization.isEnglish ? "en_US_POSIX" : "zh_CN"); f.calendar=calendar; f.timeZone=calendar.timeZone
        if calendar.isDate(date,inSameDayAs:now) { f.dateFormat=lk("'今天' HH:mm") }
        else if let y=calendar.date(byAdding:.day,value:-1,to:now),calendar.isDate(date,inSameDayAs:y) { f.dateFormat=lk("'昨天' HH:mm") }
        else { f.dateFormat=lk("M月d日 HH:mm") }
        return f.string(from:date)
    }
    public static func clock(_ date: Date,now: Date = Date(),calendar: Calendar = .current) -> String {
        let f=DateFormatter(); f.locale=Locale(identifier:Localization.isEnglish ? "en_US_POSIX" : "zh_CN"); f.calendar=calendar; f.timeZone=calendar.timeZone
        f.dateFormat=calendar.isDate(date,inSameDayAs:now) ? "HH:mm" : lk("M月d日 HH:mm")
        return f.string(from:date)
    }
}

public enum KeepAwakeMode: String, CaseIterable, Codable, Sendable {
    case off, systemOnly, systemAndDisplay
    public static let preferenceKey="keepAwakeMode"
    public static let defaultMode=KeepAwakeMode.off
    public var title: String {
        switch self {
        case .off: return lk("关闭")
        case .systemOnly: return lk("息屏不休眠（允许黑屏，合盖自动保活）")
        case .systemAndDisplay: return lk("常亮不休眠（屏幕与系统常开）")
        }
    }
    public var menuTitle: String {
        switch self {
        case .off: return lk("防休眠")
        case .systemOnly: return lk("防休眠：息屏不休眠")
        case .systemAndDisplay: return lk("防休眠：常亮不休眠")
        }
    }
}

public struct KeepAwakePlan: Equatable, Sendable {
    public var preventIdleSystemSleep: Bool
    public var preventSystemSleep: Bool
    public var preventIdleDisplaySleep: Bool
    public var wakeDisplayOnSleepEvent: Bool
    public init(preventIdleSystemSleep: Bool,preventSystemSleep: Bool,preventIdleDisplaySleep: Bool,wakeDisplayOnSleepEvent: Bool) {
        self.preventIdleSystemSleep=preventIdleSystemSleep
        self.preventSystemSleep=preventSystemSleep
        self.preventIdleDisplaySleep=preventIdleDisplaySleep
        self.wakeDisplayOnSleepEvent=wakeDisplayOnSleepEvent
    }
    public static let inactive=KeepAwakePlan(preventIdleSystemSleep:false,preventSystemSleep:false,preventIdleDisplaySleep:false,wakeDisplayOnSleepEvent:false)
    public var isActive: Bool { preventIdleSystemSleep || preventSystemSleep || preventIdleDisplaySleep }
    public var expectedAssertionTypes: Set<String> {
        var out=Set<String>()
        if preventIdleSystemSleep { out.insert("PreventUserIdleSystemSleep") }
        if preventSystemSleep { out.insert("PreventSystemSleep") }
        if preventIdleDisplaySleep { out.insert("PreventUserIdleDisplaySleep") }
        return out
    }
}

public enum KeepAwakePolicy {
    /// Computes which IOKit power assertions to hold for `mode` and whether the MacBook lid is closed (`clamshell`).
    /// When the lid is closed, macOS forces `Clamshell Sleep` 5 s after the external monitor turns off even on AC power
    /// with `sleep = 0`, so `.systemOnly` automatically upgrades to hold `PreventUserIdleDisplaySleep` while in clamshell mode.
    public static func plan(mode: KeepAwakeMode,clamshell: Bool) -> KeepAwakePlan {
        switch mode {
        case .off:
            return .inactive
        case .systemOnly:
            return KeepAwakePlan(preventIdleSystemSleep:true,preventSystemSleep:true,preventIdleDisplaySleep:clamshell,wakeDisplayOnSleepEvent:clamshell)
        case .systemAndDisplay:
            return KeepAwakePlan(preventIdleSystemSleep:true,preventSystemSleep:true,preventIdleDisplaySleep:true,wakeDisplayOnSleepEvent:true)
        }
    }
    public static func satisfied(plan: KeepAwakePlan,activeAssertionTypes: Set<String>) -> Bool {
        plan.expectedAssertionTypes.isSubset(of:activeAssertionTypes)
    }
}
