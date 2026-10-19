// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// 桌面管理 (shared layout mode only): add / remove Spaces by driving Mission Control through Accessibility.
/// Pure decision logic lives here so every safeguard is unit tested; the AX driver is in MacAdapters.
public enum AutoSpaces {
    public static let addPreferenceKey="autoAddSpaces"
    public static let removePreferenceKey="autoRemoveMigratedSpaces"
    /// Default for new installs (an explicit user choice is always kept). On: both actions are guarded and fall back to notices.
    public static let defaultEnabled=true
    /// Removing migrated Spaces defaults to off: removing on unplug forces a re-add (Mission Control flash) on every replug.
    public static let removeDefaultEnabled=false
    /// 0.6.8: removing migrated Spaces is hidden from every UI and forced off. Deleting an empty external desktop on
    /// unplug renumbers the desktops the saved layout refers to ("desktop 3"), so the next restore puts windows on the
    /// wrong desktops. The stored preference is left untouched but ignored; set this to true to bring the feature back.
    public static let removeAvailable=false
    /// The single decision point for removing Spaces: the stored preference only counts while the feature is available.
    public static func removeEffective(stored: Bool) -> Bool { removeAvailable && stored }
    /// Value for the diagnostics env line.
    public static func removeLogValue(stored: Bool) -> String { removeAvailable ? "\(stored)" : "false(hidden)" }
    /// Never add or remove more than this many Spaces in one run.
    public static let maxPerRun=6
    /// Whole run must finish within this many seconds.
    public static let runTimeout: TimeInterval=20
    /// Each single action must be confirmed by a Space-count readback within this many seconds.
    public static let stepTimeout: TimeInterval=3

    public enum Blocker: Equatable, CustomStringConvertible {
        case disabled, fullScreenActive, tooMany(Int), nothingToDo, separateSpacesOff
        public var description: String {
            switch self {
            case .disabled: return lk("开关未打开")
            case .fullScreenActive: return lk("有全屏或分屏 App，暂不自动操作桌面")
            case .tooMany(let n): return lk("需要处理 %@ 个桌面，超过单次上限 %@", "\(n)", "\(maxPerRun)")
            case .nothingToDo: return lk("无需操作")
            case .separateSpacesOff: return lk("「显示器具有单独的空间」已关闭")
            }
        }
    }

    /// True when any display currently has a full-screen / split-view (or unrecognized) Space.
    public static func fullScreenActive(_ spaces: [Space]) -> Bool { spaces.contains { $0.kind != .ordinary } }

    /// How many Spaces to add on the external display, or why not.
    public static func planAdd(enabled: Bool,needed: Int,available: Int,spaces: [Space]) -> Result<Int,BlockerError> {
        guard enabled else { return .failure(BlockerError(.disabled)) }
        let missing=max(0,needed-available)
        guard missing>0 else { return .failure(BlockerError(.nothingToDo)) }
        guard !fullScreenActive(spaces) else { return .failure(BlockerError(.fullScreenActive)) }
        guard missing<=maxPerRun else { return .failure(BlockerError(.tooMany(missing))) }
        return .success(missing)
    }

    /// Which built-in Spaces may be removed after an unplug. Only Spaces that (1) were on the external display just before
    /// the unplug, (2) are now on the built-in display, (3) hold no window, and (4) are not the active Space.
    /// The built-in display always keeps at least one Space, and the ones it had before the unplug are never touched.
    /// Returns ids in the order they appear on the built-in display.
    public static func planRemove(enabled: Bool,before: SpaceCensus,after: SpaceCensus,occupied: Set<UInt64>,active: Set<UInt64>,spaces: [Space]) -> Result<[UInt64],BlockerError> {
        guard enabled else { return .failure(BlockerError(.disabled)) }
        guard before.externalCount>0,after.externalCount==0 else { return .failure(BlockerError(.nothingToDo)) }
        guard !fullScreenActive(spaces) else { return .failure(BlockerError(.fullScreenActive)) }
        let migrated=Set(before.external)
        let original=Set(before.builtIn)
        var candidates=after.builtIn.filter { migrated.contains($0) && !original.contains($0) && !occupied.contains($0) && !active.contains($0) }
        let keep=after.builtIn.count-candidates.count
        if keep<1 { candidates.removeLast(1-keep) }
        guard !candidates.isEmpty else { return .failure(BlockerError(.nothingToDo)) }
        guard candidates.count<=maxPerRun else { return .failure(BlockerError(.tooMany(candidates.count))) }
        return .success(candidates)
    }

    /// After pressing "+": exactly one new ordinary Space on the target display, and every old one still there.
    public static func verifyAdded(before: [UInt64],after: [UInt64]) -> Bool {
        after.count==before.count+1 && Set(before).isSubset(of:Set(after))
    }
    /// After removing `removed`: exactly that Space is gone and every other one is still there.
    public static func verifyRemoved(_ removed: UInt64,before: [UInt64],after: [UInt64]) -> Bool {
        after.count==before.count-1 && !after.contains(removed) && Set(before.filter{ $0 != removed })==Set(after)
    }
    /// Mission Control lists a display's Spaces in the same order as SkyLight. Only act when the counts agree.
    public static func buttonIndex(of id: UInt64,ordered: [UInt64],buttonCount: Int) -> Int? {
        guard buttonCount==ordered.count,let i=ordered.firstIndex(of:id) else { return nil }
        return i
    }
}

public struct BlockerError: Error, Equatable {
    public var blocker: AutoSpaces.Blocker
    public init(_ blocker: AutoSpaces.Blocker) { self.blocker=blocker }
}

/// 0.6.9: how Mission Control is opened for auto-add, verified each time. 10/17 15:26:41 failed with a single try
/// right after the monitor came back ("调度中心没有打开"): WindowManager was still re-laying out the displays.
/// Now up to three tries with growing waits and a short pause between them; each try first checks Mission Control
/// is not already open, so ⌃↑ (a toggle) is never sent into an already-open Mission Control.
public enum MissionControlOpening {
    public enum Method: String, Equatable { case app, shortcut
        public var label: String { self == .app ? lk("打开调度中心") : lk("⌃↑ 快捷键") }
    }
    public struct Attempt: Equatable { public var method: Method; public var wait: TimeInterval
        public init(_ method: Method,_ wait: TimeInterval) { self.method=method; self.wait=wait }
    }
    public static func attempts(ctrlUpEnabled: Bool) -> [Attempt] {
        ctrlUpEnabled ? [Attempt(.app,2.5),Attempt(.shortcut,3),Attempt(.app,4)] : [Attempt(.app,2.5),Attempt(.app,3.5),Attempt(.app,4.5)]
    }
    /// Pause after a failed try before the next one.
    public static func backoff(after attempt: Int) -> TimeInterval { 0.5*Double(attempt+1) }
    public static func failureText(tried: [Method],ctrlUpEnabled: Bool) -> String {
        lk("调度中心没有打开（试了 %@ 次：%@）", "\(tried.count)", tried.map(\.label).joined(separator:lk("、")))
            + (ctrlUpEnabled ? "" : lk("；系统设置里调度中心的 ⌃↑ 快捷键已关闭"))
    }
}
