// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public enum AutoRestoreMode: String, CaseIterable, Codable {
    case off, ask, auto
    public static let defaultMode=AutoRestoreMode.ask
    public var title: String {
        switch self { case .off: return lk("关闭恢复"); case .ask: return lk("先询问恢复"); case .auto: return lk("自动恢复") }
    }
}

/// Pure debounce/state machine for "monitor reconnected or Mac woke → offer restore".
/// Screen events restart a settle timer; once the screen fingerprint has been stable for
/// `settleInterval`, it triggers when the monitor changed since the last stable state (or a wake
/// happened) and a saved layout exists. Launching never triggers: the initial monitor is the baseline.
public struct ReconnectWatch {
    public enum Event: Equatable { case screens, wake }
    public enum Decision: Equatable { case idle, wait(until: Date), settled, trigger(monitorKey: String) }
    public let settleInterval: TimeInterval
    public private(set) var lastStableKey: String?
    public private(set) var pendingSince: Date?
    public private(set) var pendingWake=false
    private var fingerprint: String?
    public init(initialMonitorKey: String?, settleInterval: TimeInterval = 3) { lastStableKey=initialMonitorKey; self.settleInterval=settleInterval }
    public var isPending: Bool { pendingSince != nil }
    public mutating func note(_ event: Event, at time: Date, fingerprint: String) {
        pendingSince=time; self.fingerprint=fingerprint
        if event == .wake { pendingWake=true }
    }
    /// Call after `settleInterval` (or on any timer tick). `monitorKey` is the current external monitor's key (nil if none).
    public mutating func evaluate(at time: Date, fingerprint current: String, monitorKey: String?, hasLayout: Bool, mode: AutoRestoreMode) -> Decision {
        guard let since=pendingSince else { return .idle }
        if current != fingerprint { fingerprint=current; pendingSince=time; return .wait(until:time+settleInterval) }
        if time<since+settleInterval { return .wait(until:since+settleInterval) }
        pendingSince=nil
        let changed=monitorKey != lastStableKey, woke=pendingWake
        pendingWake=false; lastStableKey=monitorKey
        guard mode != .off,let monitorKey,changed || woke,hasLayout else { return .settled }
        return .trigger(monitorKey:monitorKey)
    }
}
