// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// Per-window preconditions for a cross-Space move, shared by the preview (to flag items early)
/// and the executor's permit builder (so one undeterminable window never aborts the whole batch).
public enum MoveScope {
    public static let noProcessStart="这个应用（例如访达）没有可验证的进程启动时间，不能自动移到别的桌面。可以手动把它拖到目标桌面，再恢复一次来调整位置和大小。"
    public static func problem(window: ObservedWindow,targetSpace: UInt64,targetDisplay: String,snapshot: Snapshot) -> String? {
        guard window.spaceIDs.count==1 else { return "窗口所在桌面未知或同时属于多个桌面" }
        guard window.processStartedAt != nil else { return noProcessStart }
        guard snapshot.spaces.contains(where:{$0.id==window.spaceIDs[0] && $0.kind == .ordinary}) else { return "无法确定窗口当前所在的普通桌面" }
        guard snapshot.spaces.contains(where:{$0.id==targetSpace && $0.kind == .ordinary && $0.displayToken==targetDisplay}) else { return "目标桌面已不存在或不在这块屏幕上" }
        return nil
    }
    public static func needsMove(_ entry: PlanEntry) -> Bool {
        guard let w=entry.window,let target=entry.targetSpace else { return false }
        return w.spaceIDs != [target]
    }
    /// Builds one permit per ready cross-Space entry. Entries whose scope cannot be determined are
    /// marked blocked with a per-item reason; the others keep their permits and proceed.
    public static func partition<P>(_ plan: RestorePlan,snapshot: Snapshot,makePermit: (PlanEntry) throws -> P) -> (plan: RestorePlan,permits: [P],blocked: [Int:String]) {
        var plan=plan; var permits=[P](); var blocked=[Int:String]()
        for i in plan.entries.indices where plan.entries[i].status == .ready && needsMove(plan.entries[i]) {
            let entry=plan.entries[i]
            var why: String?
            if let w=entry.window,let target=entry.targetSpace,let display=entry.targetDisplay {
                why=problem(window:w,targetSpace:target,targetDisplay:display,snapshot:snapshot)
                if why==nil { do { permits.append(try makePermit(entry)) } catch { why="跨桌面授权范围无法确定（\(error)）" } }
            } else { why="缺少窗口或目标桌面信息" }
            if let why { plan.entries[i].status = .blocked; plan.entries[i].reason="无法跨桌面移动：\(why)"; blocked[i]=plan.entries[i].reason }
        }
        return (plan,permits,blocked)
    }
}
