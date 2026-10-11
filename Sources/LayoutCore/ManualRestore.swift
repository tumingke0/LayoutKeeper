// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public enum MonitorRestorePlanner {
    public static func plan(record: MonitorLayoutRecord, monitor: MonitorIdentity, displayToken: String, snapshot: Snapshot, groupSpaces: [String:UInt64], allowCrossSpace: Bool = false) throws -> RestorePlan {
        try record.validate()
        guard record.monitor.key==monitor.key,
              snapshot.displays.filter({$0.role == .external}).count==1,
              snapshot.displays.contains(where:{$0.token==displayToken && $0.role == .external}) else { throw LayoutError.unsupported }
        let bindings=groupSpaces.map { DesktopBinding(label:$0.key,role:.external,spaceID:$0.value,snapshot:snapshot) }.filter { binding in
            snapshot.spaces.contains{$0.id==binding.spaceID && $0.kind == .ordinary && $0.displayToken==displayToken}
        }
        var plan=try Planner.plan(profile:record.profile,snapshot:snapshot,bindings:bindings,canMoveSpaces:true)
        let collapsed=Set(groupSpaces.values.filter { target in groupSpaces.values.filter{$0==target}.count>1 })
        for i in plan.entries.indices {
            if plan.entries[i].reason.contains("多个窗口匹配") {
                plan.entries[i].status = .skipped
                plan.entries[i].reason="多个窗口匹配，已跳过；不会猜测应该调整哪一个"
            } else if let target=groupSpaces[plan.entries[i].saved.desktopLabel],collapsed.contains(target) {
                plan.entries[i].status = .blocked
                plan.entries[i].reason="多个保存窗口组选择了同一桌面；桌面数量不足时不会合并布局"
            } else if plan.entries[i].status == .ready,let window=plan.entries[i].window,let target=plan.entries[i].targetSpace,window.spaceIDs != [target], !allowCrossSpace {
                plan.entries[i].status = .blocked
                plan.entries[i].reason="需要跨桌面移动；请勾选「本次启用跨桌面恢复」（仅在已验证的系统版本可用）"
            }
        }
        return plan
    }
}
public enum JournalEntryState: String, Codable { case prepared, attempted, verified, unchanged, rolledBack, rollbackFailed, rollbackBlocked, blocked }
public struct RestoreJournalEntry: Codable {
    public var planIndex: Int
    public var before: ObservedWindow
    public var targetFrame: Rect
    public var targetDisplay: String
    public var targetSpace: UInt64? = nil
    public var sourceDisplay: String? = nil
    public var after: ObservedWindow?
    public var state: JournalEntryState
    public var detail: String
    public var tokenPinned: Bool? = nil
}
public struct RestoreJournal: Codable {
    public var schemaVersion=1
    public var id: UUID
    public var createdAt: Date
    public var session: UUID
    public var topology: String
    public var entries: [RestoreJournalEntry]
    public var canUndo: Bool { entries.contains { [.verified,.rollbackFailed,.rollbackBlocked].contains($0.state) && $0.after != nil } }
    public func validate() throws {
        guard schemaVersion==1,!topology.isEmpty,!entries.isEmpty,
              Set(entries.map{$0.before.token}).count==entries.count,
              Set(entries.map(\.planIndex)).count==entries.count,
              entries.allSatisfy({$0.planIndex>=0 && !$0.before.token.isEmpty && $0.before.selector.usable && $0.before.frame.valid && $0.before.ordinary && !$0.before.fullScreen && !$0.before.minimized && $0.before.spaceIDs.count==1 && $0.targetFrame.valid && !$0.targetDisplay.isEmpty}) else { throw LayoutError.invalidProfile }
    }
}
public struct ManualRestoreReport {
    public var journal: RestoreJournal?
    public var results: [RestoreResult]
    public var persistenceIssues: [String]
}

// Cross-Space execution requires an explicitly supplied mover; default execution stays same-Space.
public enum ManualRestorer {
    private static func topology(_ journal: RestoreJournal,_ snapshot: Snapshot) -> Bool { journal.session==snapshot.session && journal.topology==snapshot.topology }
    private static func targetSpace(_ entry: RestoreJournalEntry) -> UInt64 { entry.targetSpace ?? entry.before.spaceIDs[0] }
    private static func sourceDisplay(_ entry: RestoreJournalEntry) -> String { entry.sourceDisplay ?? entry.targetDisplay }
    private static func validRoute(_ entry: RestoreJournalEntry,_ snapshot: Snapshot) -> Bool {
        snapshot.spaces.contains{$0.id==entry.before.spaceIDs[0] && $0.kind == .ordinary && $0.displayToken==sourceDisplay(entry)} &&
        snapshot.spaces.contains{$0.id==targetSpace(entry) && $0.kind == .ordinary && $0.displayToken==entry.targetDisplay} &&
        snapshot.displays.contains{$0.token==entry.targetDisplay} && snapshot.displays.contains{$0.token==sourceDisplay(entry)}
    }
    private static func identity(_ current: ObservedWindow,_ before: ObservedWindow,_ snapshot: Snapshot,pinned: Bool = false) -> Bool {
        current.token==before.token && current.selector==before.selector && current.processStartedAt==before.processStartedAt &&
        current.ordinary && !current.fullScreen && !current.minimized && current.frame.valid && current.spaceIDs.count==1 &&
        (pinned ? snapshot.windows.filter{$0.token==before.token}.count==1 : snapshot.windows.filter{before.selector.matches($0.selector)}.count==1)
    }
    private static func inside(_ frame: Rect,_ bounds: Rect) -> Bool {
        frame.valid && bounds.valid && frame.x>=bounds.x-0.01 && frame.y>=bounds.y-0.01 && frame.x+frame.width<=bounds.x+bounds.width+0.01 && frame.y+frame.height<=bounds.y+bounds.height+0.01
    }
    private static func live(_ entry: RestoreJournalEntry,_ journal: RestoreJournal,_ windows: WindowBackend) throws -> ObservedWindow? {
        let snapshot=try windows.snapshot()
        guard topology(journal,snapshot),validRoute(entry,snapshot),let current=try windows.readWindow(token:entry.before.token),identity(current,entry.before,snapshot,pinned:entry.tokenPinned==true),
              current.spaceIDs==entry.before.spaceIDs || current.spaceIDs==[targetSpace(entry)] else { return nil }
        return current
    }
    private static func poll(_ entry: RestoreJournalEntry,_ journal: RestoreJournal,_ windows: WindowBackend,space: UInt64,frame: Rect? = nil,polls: Int,pause: () -> Void) throws -> ObservedWindow? {
        for attempt in 0..<max(polls,1) {
            if attempt>0 { pause() }
            guard let current=try live(entry,journal,windows) else { return nil }
            if current.spaceIDs==[space],frame==nil || current.frame.near(frame!) { return current }
        }
        return nil
    }
    public static func execute(_ plan: RestorePlan,windows: WindowBackend,spaces: SpacesBackend? = nil,approved: Bool,polls: Int = 5,pause: () -> Void = {},persist: (RestoreJournal) throws -> Void) -> ManualRestoreReport {
        var results=plan.entries.map{RestoreResult(title:$0.saved.selector.title,outcome:$0.status == .skipped ? .skipped : .blocked,detail:$0.reason)}
        func blockReady(_ detail: String) { for i in plan.entries.indices where plan.entries[i].status == .ready { results[i].detail=detail } }
        guard approved else { blockReady("未确认此预览，没有执行写操作");return ManualRestoreReport(journal:nil,results:results,persistenceIssues:[]) }
        var journal=RestoreJournal(id:UUID(),createdAt:Date(),session:plan.session,topology:plan.topology,entries:[])
        var issues=[String]()
        do {
            let snapshot=try windows.snapshot();guard topology(journal,snapshot) else { throw LayoutError.readbackUnavailable }
            for i in plan.entries.indices where plan.entries[i].status == .ready {
                let planned=plan.entries[i]
                guard let before=planned.window,let frame=planned.targetFrame,let display=planned.targetDisplay,let target=planned.targetSpace,
                      before.spaceIDs.count==1,let source=snapshot.spaces.first(where:{$0.id==before.spaceIDs[0] && $0.kind == .ordinary}),
                      let bounds=snapshot.displays.first(where:{$0.token==display})?.visible,inside(frame,bounds),
                      let current=try windows.readWindow(token:before.token),identity(current,before,snapshot,pinned:planned.tokenPinned==true),current.spaceIDs==before.spaceIDs,current.frame.near(before.frame,tolerance:0.01) else {
                    results[i].detail="预览过期，窗口、显示器或桌面无法可靠确认";continue
                }
                guard before.spaceIDs==[target] || spaces?.canMove==true else { results[i].detail="没有获准的跨桌面后端，未移动窗口";continue }
                let entry=RestoreJournalEntry(planIndex:i,before:current,targetFrame:frame,targetDisplay:display,targetSpace:target,sourceDisplay:source.displayToken,after:nil,state:.prepared,detail:"等待执行",tokenPinned:planned.tokenPinned)
                guard validRoute(entry,snapshot) else { results[i].detail="源或目标桌面已改变";continue }
                journal.entries.append(entry)
            }
            guard !journal.entries.isEmpty else { return ManualRestoreReport(journal:nil,results:results,persistenceIssues:[]) }
            try journal.validate();try persist(journal)
        } catch { blockReady("执行前快照无法保存或复核，没有移动窗口：\(error)");return ManualRestoreReport(journal:nil,results:results,persistenceIssues:["执行前快照：\(error)"]) }
        var failed=false
        for i in journal.entries.indices {
            if failed { journal.entries[i].state = .blocked;journal.entries[i].detail="前一项失败，已停止后续恢复";continue }
            let entry=journal.entries[i];let target=targetSpace(entry);var writeInvoked=false
            do {
                guard let initial=try live(entry,journal,windows),initial.spaceIDs==entry.before.spaceIDs,initial.frame.near(entry.before.frame,tolerance:0.01) else { throw LayoutError.readbackUnavailable }
                if initial.spaceIDs==[target] && initial.frame.near(entry.targetFrame) {
                    journal.entries[i].after=initial;journal.entries[i].state = .unchanged;journal.entries[i].detail="已在目标位置和桌面，没有写入窗口";try persist(journal);continue
                }
                journal.entries[i].state = .attempted;journal.entries[i].detail="已保存快照与写入意图"
                do { try persist(journal) } catch { journal.entries[i].state = .blocked;journal.entries[i].detail="写前日志失败，没有写入此窗口：\(error)";issues.append(journal.entries[i].detail);failed=true;continue }
                guard var current=try live(entry,journal,windows),current.spaceIDs==entry.before.spaceIDs,current.frame.near(entry.before.frame,tolerance:0.01) else { throw LayoutError.readbackUnavailable }
                if current.spaceIDs != [target] {
                    guard let spaces,spaces.canMove else { throw LayoutError.unsupported }
                    writeInvoked=true;try spaces.move(window:current,to:target)
                    guard let moved=try poll(entry,journal,windows,space:target,polls:polls,pause:pause) else { throw LayoutError.readbackUnavailable }
                    current=moved;journal.entries[i].after=moved;journal.entries[i].detail="目标普通桌面已回读，准备调整几何";try persist(journal)
                }
                if !current.frame.near(entry.targetFrame) {
                    journal.entries[i].after=current;try persist(journal)
                    guard let atWrite=try live(entry,journal,windows),atWrite.spaceIDs==[target],atWrite.frame.near(current.frame,tolerance:0.01) else { throw LayoutError.readbackUnavailable }
                    writeInvoked=true;try windows.setFrame(window:atWrite,to:entry.targetFrame)
                }
                guard let actual=try poll(entry,journal,windows,space:target,frame:entry.targetFrame,polls:polls,pause:pause) else { throw LayoutError.readbackUnavailable }
                journal.entries[i].after=actual;journal.entries[i].state = .verified;journal.entries[i].detail="目标普通桌面、位置和大小均已回读验证";try persist(journal)
            } catch {
                if writeInvoked { journal.entries[i].after=(try? live(entry,journal,windows)) ?? journal.entries[i].after;journal.entries[i].state = .attempted;journal.entries[i].detail="恢复未通过验证：\(error)" }
                else { journal.entries[i].state = .blocked;journal.entries[i].detail="写入前窗口或桌面改变，没有写入此窗口" }
                failed=true
            }
        }
        if failed { rollback(&journal,windows:windows,spaces:spaces,polls:polls,pause:pause,persist:persist,issues:&issues) }
        do { try persist(journal) } catch { issues.append("最终日志更新失败：\(error)") }
        for entry in journal.entries {
            let outcome: Outcome = [.verified,.unchanged].contains(entry.state) ? .verified : (entry.state == .blocked ? .blocked : .failed)
            results[entry.planIndex]=RestoreResult(title:results[entry.planIndex].title,outcome:outcome,detail:entry.detail,observed:entry.after)
        }
        return ManualRestoreReport(journal:journal,results:results,persistenceIssues:issues)
    }
    private static func rollback(_ journal: inout RestoreJournal,windows: WindowBackend,spaces: SpacesBackend?,polls: Int,pause: () -> Void,persist: (RestoreJournal) throws -> Void,issues: inout [String]) {
        for i in journal.entries.indices.reversed() where [.attempted,.verified,.rollbackFailed,.rollbackBlocked].contains(journal.entries[i].state) {
            let entry=journal.entries[i];var writeInvoked=false
            do {
                guard let after=entry.after,var current=try live(entry,journal,windows),current.spaceIDs==after.spaceIDs,current.frame.near(after.frame,tolerance:0.01) else {
                    journal.entries[i].state = .rollbackBlocked;journal.entries[i].detail="无法安全撤销：身份、桌面或位置改变，或缺少写后回读";continue
                }
                if current.spaceIDs != entry.before.spaceIDs {
                    guard let spaces,spaces.canMove else { journal.entries[i].state = .rollbackBlocked;journal.entries[i].detail="跨桌面撤销未获准，没有派发";continue }
                    try persist(journal)
                    guard let atWrite=try live(entry,journal,windows),atWrite.spaceIDs==current.spaceIDs,atWrite.frame.near(current.frame,tolerance:0.01) else { journal.entries[i].state = .rollbackBlocked;journal.entries[i].detail="撤销前窗口改变，保留后续调整";continue }
                    writeInvoked=true;try spaces.move(window:atWrite,to:entry.before.spaceIDs[0])
                    guard let returned=try poll(entry,journal,windows,space:entry.before.spaceIDs[0],polls:polls,pause:pause) else { throw LayoutError.readbackUnavailable }
                    current=returned;journal.entries[i].after=returned;try persist(journal)
                }
                if !current.frame.near(entry.before.frame,tolerance:0.01) {
                    try persist(journal)
                    guard let atWrite=try live(entry,journal,windows),atWrite.spaceIDs==entry.before.spaceIDs,atWrite.frame.near(current.frame,tolerance:0.01) else { journal.entries[i].state = .rollbackBlocked;journal.entries[i].detail="撤销前窗口改变，保留后续调整";continue }
                    writeInvoked=true;try windows.setFrame(window:atWrite,to:entry.before.frame)
                }
                guard let restored=try poll(entry,journal,windows,space:entry.before.spaceIDs[0],frame:entry.before.frame,polls:polls,pause:pause) else { throw LayoutError.readbackUnavailable }
                journal.entries[i].after=restored;journal.entries[i].state = .rolledBack;journal.entries[i].detail="已回滚到原普通桌面、位置和大小。\(entry.detail)"
            } catch {
                if writeInvoked { journal.entries[i].after=(try? live(entry,journal,windows)) ?? journal.entries[i].after }
                journal.entries[i].state = .rollbackFailed;journal.entries[i].detail="回滚失败：\(error)；请检查实际窗口，可显式重试撤销"
            }
            do { try persist(journal) } catch { issues.append("回滚日志更新失败：\(error)") }
        }
    }
    public static func undo(_ original: RestoreJournal,windows: WindowBackend,spaces: SpacesBackend? = nil,approved: Bool,polls: Int = 5,pause: () -> Void = {},persist: (RestoreJournal) throws -> Void) -> ManualRestoreReport {
        var journal=original;var issues=[String]()
        guard approved else { return ManualRestoreReport(journal:journal,results:journal.entries.map{RestoreResult(title:$0.before.selector.title,outcome:.blocked,detail:"未确认撤销，没有写入窗口")},persistenceIssues:[]) }
        do { try journal.validate();try persist(journal) } catch { return ManualRestoreReport(journal:journal,results:journal.entries.map{RestoreResult(title:$0.before.selector.title,outcome:.blocked,detail:"撤销前日志失败：\(error)")},persistenceIssues:["撤销前日志：\(error)"]) }
        let eligible=Set(journal.entries.indices.filter{[.verified,.rollbackFailed,.rollbackBlocked].contains(journal.entries[$0].state)})
        rollback(&journal,windows:windows,spaces:spaces,polls:polls,pause:pause,persist:persist,issues:&issues)
        do { try persist(journal) } catch { issues.append("撤销最终日志更新失败：\(error)") }
        let results=journal.entries.enumerated().map { index,entry in
            let outcome: Outcome = !eligible.contains(index) ? .skipped : (entry.state == .rolledBack ? .verified : (entry.state == .rollbackBlocked ? .blocked : .failed))
            return RestoreResult(title:entry.before.selector.title,outcome:outcome,detail:eligible.contains(index) ? entry.detail : "此窗口无需撤销",observed:entry.after)
        }
        return ManualRestoreReport(journal:journal,results:results,persistenceIssues:issues)
    }
}
public enum RestoreJournalStore {
    private static func encoded(_ journal: RestoreJournal) throws -> Data {
        try journal.validate(); let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; return try encoder.encode(journal)
    }
    public static func create(_ journal: RestoreJournal,in directory: URL) throws -> URL {
        let data=try encoded(journal)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("restore-\(journal.id.uuidString).json")
        try data.write(to:url,options:.withoutOverwriting)
        _=try load(from:url); return url
    }
    public static func update(_ journal: RestoreJournal,at url: URL) throws {
        let original=try load(from:url)
        guard original.id==journal.id,original.session==journal.session,original.topology==journal.topology,
              original.entries.map(\.before)==journal.entries.map(\.before),original.entries.map(\.targetFrame)==journal.entries.map(\.targetFrame),original.entries.map(\.targetDisplay)==journal.entries.map(\.targetDisplay),original.entries.map(\.targetSpace)==journal.entries.map(\.targetSpace),original.entries.map(\.sourceDisplay)==journal.entries.map(\.sourceDisplay) else { throw LayoutError.invalidProfile }
        try encoded(journal).write(to:url,options:.atomic)
        _=try load(from:url)
    }
    public static func load(from url: URL) throws -> RestoreJournal {
        let journal=try JSONDecoder().decode(RestoreJournal.self,from:Data(contentsOf:url)); try journal.validate(); return journal
    }
}
