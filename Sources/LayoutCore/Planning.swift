// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
public enum Planner {
    private static func resolved(_ b: DesktopBinding, _ s: Snapshot) -> Bool {
        b.session == s.session && b.topology == s.topology && s.spaces.contains { space in
            space.id == b.spaceID && space.kind == .ordinary && s.displays.contains { $0.token == space.displayToken && $0.role == b.role }
        }
    }
    public static func plan(profile: Profile, snapshot s: Snapshot, bindings: [DesktopBinding], canMoveSpaces: Bool) throws -> RestorePlan {
        try profile.validate()
        var entries: [PlanEntry] = []
        for saved in profile.windows {
            func blocked(_ why: String) -> PlanEntry { PlanEntry(saved:saved,status:.blocked,reason:why) }
            func skipped(_ why: String) -> PlanEntry { PlanEntry(saved:saved,status:.skipped,reason:why) }
            let matches=s.windows.filter { saved.selector.matches($0.selector) }
            guard !matches.isEmpty else { entries.append(skipped("未找到匹配窗口；不会启动应用或猜测标题")); continue }
            guard matches.count == 1 else { entries.append(blocked("多个窗口匹配；需文档标识或精确标题")); continue }
            let w=matches[0]
            guard w.ordinary, !w.fullScreen, !w.minimized, w.spaceIDs.count == 1,
                  let source=s.spaces.first(where:{$0.id==w.spaceIDs[0]}), source.kind == .ordinary else {
                entries.append(skipped("跳过全屏/Split View、最小化、非普通窗口或未知/多桌面成员关系")); continue
            }
            let displays=s.displays.filter{$0.role == saved.displayRole}
            guard displays.count == 1 else { entries.append(blocked("目标屏幕缺失或有多个同角色屏幕")); continue }
            let candidates=bindings.filter{$0.label==saved.desktopLabel && $0.role==saved.displayRole}
            guard candidates.count == 1, resolved(candidates[0],s) else { entries.append(blocked("桌面用途尚未绑定，或绑定已因换屏/重启失效")); continue }
            let target=candidates[0].spaceID
            guard w.spaceIDs == [target] || canMoveSpaces else { entries.append(blocked("跨桌面后端在此系统未验证；禁止以坐标代替桌面恢复")); continue }
            guard displays[0].visible.valid, w.frame.valid else { entries.append(blocked("无有效屏幕或窗口尺寸")); continue }
            entries.append(PlanEntry(saved:saved,status:.ready,reason:w.spaceIDs == [target] ? "同一普通桌面：仅恢复尺寸和位置" : "需要先移桌面，再恢复尺寸和位置",window:w,targetSpace:target,targetDisplay:displays[0].token,targetFrame:saved.normalizedFrame.fitted(in:displays[0].visible)))
        }
        let tokens=entries.compactMap{$0.window?.token}
        for i in entries.indices {
            if let token=entries[i].window?.token, tokens.filter({$0==token}).count > 1 {
                entries[i].status = .blocked; entries[i].reason = "配置中多条规则指向同一窗口"
            }
        }
        return RestorePlan(session:s.session,topology:s.topology,entries:entries)
    }
    public static func capture(location: String, snapshot s: Snapshot, bindings: [DesktopBinding]) throws -> (Profile, [String]) {
        var saved: [SavedWindow]=[]; var issues: [String]=[]
        for w in s.windows {
            let label=w.selector.title.isEmpty ? w.selector.bundleID : w.selector.title
            guard w.ordinary, !w.fullScreen, !w.minimized, w.spaceIDs.count == 1,
                  let source=s.spaces.first(where:{$0.id==w.spaceIDs[0]}), source.kind == .ordinary,
                  let display=s.displays.first(where:{$0.token==source.displayToken}), display.visible.valid, w.frame.valid,
                  w.selector.usable, s.windows.filter({w.selector.matches($0.selector)}).count == 1 else {
                issues.append("\(label)：跳过不支持或无法唯一识别的窗口"); continue
            }
            let b=bindings.filter { $0.spaceID==source.id && $0.role==display.role && resolved($0,s) }
            guard b.count == 1, !b[0].label.isEmpty else { issues.append("\(label)：请先绑定当前桌面的用途"); continue }
            saved.append(SavedWindow(selector:w.selector,displayRole:display.role,desktopLabel:b[0].label,normalizedFrame:w.frame.normalized(in:display.visible)))
        }
        let profile=Profile(location:location,windows:saved); try profile.validate()
        return (profile,issues)
    }
}
public enum Restorer {
    public static func execute(_ plan: RestorePlan, windows: WindowBackend, spaces: SpacesBackend, approved: Bool, polls: Int = 5, pause: () -> Void = {}) -> [RestoreResult] {
        plan.entries.map { entry in
            let title=entry.saved.selector.title
            func result(_ outcome: Outcome, _ detail: String, _ observed: ObservedWindow? = nil) -> RestoreResult { RestoreResult(title:title,outcome:outcome,detail:detail,observed:observed) }
            guard entry.status == .ready else { return result(entry.status == .skipped ? .skipped : .blocked,entry.reason) }
            guard approved else { return result(.blocked,"未批准实际移动；没有执行写操作") }
            guard let original=entry.window, let target=entry.targetSpace, let frame=entry.targetFrame, let targetDisplay=entry.targetDisplay else { return result(.blocked,"无完整目标") }
            do {
                func freshTopology() throws -> Bool {
                    let s=try windows.snapshot()
                    return s.session==plan.session && s.topology==plan.topology && s.spaces.contains{$0.id==target && $0.kind == .ordinary && $0.displayToken==targetDisplay}
                }
                guard try freshTopology(), let current=try windows.readWindow(token:original.token),
                      current.selector == original.selector, current.spaceIDs == original.spaceIDs,
                      current.frame.near(original.frame), current.ordinary, !current.fullScreen, !current.minimized else {
                    return result(.blocked,"预览过期：屏幕、桌面、窗口身份或位置已改变，请重新预览")
                }
                func poll(_ predicate: (ObservedWindow) -> Bool) throws -> ObservedWindow? {
                    for attempt in 0..<max(polls,1) {
                        if attempt > 0 { pause() }
                        guard try freshTopology(), let observed=try windows.readWindow(token:original.token),
                              observed.selector==original.selector, observed.ordinary, !observed.fullScreen, !observed.minimized else { return nil }
                        if predicate(observed) { return observed }
                    }
                    return nil
                }
                if current.spaceIDs != [target] {
                    guard spaces.canMove else { return result(.blocked,"跨桌面后端未验证") }
                    try spaces.move(window:current,to:target)
                    guard try poll({$0.spaceIDs == [target]}) != nil else {
                        return result(.failed,"移桌面回读未达到目标；未继续写入坐标",try? windows.readWindow(token:original.token))
                    }
                }
                guard let atTarget=try poll({$0.spaceIDs == [target]}) else { return result(.failed,"无法确认目标桌面") }
                try windows.setFrame(window:atTarget,to:frame)
                guard let actual=try poll({$0.spaceIDs == [target] && $0.frame.near(frame)}) else {
                    return result(.failed,"位置/尺寸/桌面回读不一致；可能受应用最小尺寸或系统限制影响",try? windows.readWindow(token:original.token))
                }
                return result(.verified,"位置、尺寸和目标普通桌面均已回读验证",actual)
            } catch { return result(.failed,"操作或读取错误：\(error)",try? windows.readWindow(token:original.token)) }
        }
    }
}
public enum ProfileStore {
    public static func load(from url: URL) throws -> Profile { let p=try JSONDecoder().decode(Profile.self,from:Data(contentsOf:url)); try p.validate(); return p }
    public static func save(_ profile: Profile, to url: URL) throws {
        try profile.validate(); let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try VersionedStore.write(encoder.encode(profile),to:url)
    }
}
