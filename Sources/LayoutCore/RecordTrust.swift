// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// 0.6.11: whether a live-record scan may change the desk strip. The record is only as good as the moment it was
/// taken; on 10/21 three abnormal states fed it (and the freeze) a wrong strip:
///  - lid closed: macOS puts the built-in screen's desktops onto the external one (09:00:53, 5 → 11 desktops);
///  - screen locked / displays asleep: the scan reads no window at all (22:16 → 09:28);
///  - after wake macOS kept reporting the home monitor for ~2 minutes although it was gone (09:28:43–09:30:56).
/// In these states the last normal strip is kept, so the freeze at the unplug is the last normal record.
public enum LiveRecordTrust {
    public enum Verdict: Equatable {
        /// Normal: record as scanned.
        case normal
        /// Lid closed: keep the previous strip; windows on those desktops are recorded at their position.
        case keepDesks(String)
        /// Nothing trustworthy: do not touch the record.
        case skip(String)
        public var reason: String? {
            switch self { case .normal: return nil; case .keepDesks(let r), .skip(let r): return r }
        }
    }
    /// Seconds after a wake during which scans are not recorded (the window server and screens are still settling).
    public static let wakeGrace: TimeInterval=8
    public static func assess(snapshot s: Snapshot,displayToken: String,previous: LiveLayoutRecord?,screenLocked: Bool,sinceWake: TimeInterval?) -> Verdict {
        if screenLocked { return .skip("screen locked or displays asleep") }
        if let t=sinceWake,t<wakeGrace { return .skip(String(format:"%.0fs after wake",t)) }
        // A real desktop session always has some window (Finder, menu-bar apps' windows, …): none at all means the
        // window server could not be read (locked, asleep, or a monitor that is not really there).
        if s.windows.isEmpty { return .skip("no window readable (screen locked, asleep, or the monitor is not really there)") }
        let hasBuiltIn=s.displays.contains{ $0.role == .builtIn }
        if !hasBuiltIn,let own=previous?.builtInDesks,!own.isEmpty {
            let onExternal=s.spaces.filter{ $0.displayToken==displayToken && $0.kind == .ordinary }
            if onExternal.contains(where:{ sp in own.contains{ $0.matches(sp) } }) {
                guard previous != nil else { return .skip("lid closed, no earlier strip") }
                return .keepDesks("lid closed: the built-in screen's desktops are on the external one")
            }
        }
        return .normal
    }
}

/// 0.6.11: what the window scan's read problems mean for this restore, instead of "some window info couldn't be
/// read". Each issue starts with a bundle ID ("com.app：…") or a window token ("123:456：…").
public enum ScanIssueSummary {
    public struct Result: Equatable { public var affectedApps: [String]; public var windows: Int; public var unrelated: Int }
    public static func summarize(_ issues: [String],layoutApps: Set<String>) -> Result {
        var apps=Set<String>(), windows=0, unrelated=0
        for issue in issues {
            let head=issue.components(separatedBy:"：").first ?? ""
            if head.range(of:"^[0-9]+:[0-9]+$",options:.regularExpression) != nil { windows+=1 }
            else if layoutApps.contains(head) { apps.insert(head) }
            else if let r=head.range(of:"^[0-9]+ ",options:.regularExpression) { windows+=Int(head[r].trimmingCharacters(in:.whitespaces)) ?? 1 }
            else { unrelated+=1 }
        }
        return Result(affectedApps:apps.sorted(),windows:windows,unrelated:unrelated)
    }
    /// The preview line, nil when nothing that matters for this layout went wrong. Single windows that could not be
    /// read back (closed, or their app busy) carry no app name, so they only go to the log, like unrelated apps.
    public static func text(_ r: Result,appName: (String) -> String) -> String? {
        var parts=[String]()
        if !r.affectedApps.isEmpty { parts.append(lk("%@ 的窗口这次没读全，其中没读到的窗口不会移动；稍后点「重新预览」再试", r.affectedApps.map(appName).joined(separator:lk("、")))) }
        return parts.isEmpty ? nil : parts.joined(separator:lk("；"))+lk("。")
    }
}
