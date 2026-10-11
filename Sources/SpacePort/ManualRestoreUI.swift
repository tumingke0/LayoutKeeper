// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

extension Model {
    var restoreGroups: [String] { Array(Set(externalRestoreRecord?.profile.windows.map(\.desktopLabel) ?? [])).sorted() }
    var restoreDesktops: [Space] { externalRestoreSnapshot?.spaces.filter{$0.displayToken==restoreDisplayToken && $0.kind == .ordinary} ?? [] }
    func prepareExternalRestore() {
        guard !restoring else { return }
        externalRestorePlan=nil; externalRestoreSnapshot=nil; externalRestoreRecord=nil
        externalGroupSpaces=[:]; externalRestoreResults=[]; externalCrossSpaceAllowed=false
        refreshAuthorization()
        guard trusted,let monitor=currentExternalMonitor else { externalRestoreMessage="请保持外接屏连接，并检查当前应用的系统控制权限。"; return }
        do {
            let record=try MonitorLayoutStore.load(from:monitorRecordURL(monitor.identity))
            let observed=try externalLayoutSnapshot()
            let current=MonitorRecognition.externalMonitors()
            guard current.count==1,current[0].identity.key==monitor.identity.key,current[0].runtimeDisplayToken==monitor.runtimeDisplayToken else { throw LayoutError.readbackUnavailable }
            externalRestoreRecord=record; externalRestoreSnapshot=observed; restoreDisplayToken=monitor.runtimeDisplayToken
            rebuildExternalPreview()
            externalRestoreMessage="请为保存的窗口组选择本次连接的桌面。默认只调整同桌面窗口；本次受控跨桌面恢复需单独勾选并确认，仍须实际成员关系回读。" + (windows.issues.isEmpty ? "窗口读取可能不完整。" : "部分窗口读取失败，预览可能不完整。")
        } catch { externalRestoreMessage="无法读取恢复预览，没有移动窗口：\(error)" }
    }
    func rebuildExternalPreview() {
        guard let record=externalRestoreRecord,let snapshot=externalRestoreSnapshot,let monitor=currentExternalMonitor,let display=restoreDisplayToken else { externalRestorePlan=nil; return }
        do {
            externalRestorePlan=try MonitorRestorePlanner.plan(record:record,monitor:monitor.identity,displayToken:display,snapshot:snapshot,groupSpaces:externalGroupSpaces,allowCrossSpace:externalCrossSpaceAllowed && crossSpaceEnabled)
        } catch { externalRestorePlan=nil; externalRestoreMessage="屏幕或布局无法可靠对应，请重新读取预览。" }
    }
    func executeExternalRestore() {
        guard !restoring,var plan=externalRestorePlan else { return }
        let ready=plan.entries.filter{$0.status == .ready}
        guard !ready.isEmpty else { externalRestoreMessage="没有可执行项目，请检查预览中的原因。"; return }
        let alert=NSAlert(); alert.messageText="恢复预览中的 \(ready.count) 个窗口？"
        alert.informativeText="仅处理本次预览的可执行窗口。" + (externalCrossSpaceAllowed ? "本次包含跨桌面移动；每项先回读确认目标桌面，再写位置和大小。" : "跨桌面项目不会执行。") + "执行前保存原桌面、位置与大小；失败时尝试回滚，完成后可撤销。身份、桌面或位置变化会停止该项。"
        alert.addButton(withTitle:"确认恢复这些窗口"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        refreshAuthorization()
        guard trusted else { externalRestoreMessage=accessState.guidance; return }
        restoring=true; windows.writesApproved=true
        defer { restoring=false; windows.writesApproved=false; externalRestorePlan=nil }
        var journalURL: URL?
        var permits=[SpaceMovePermit]()
        if externalCrossSpaceAllowed {
            guard let snapshot=self.externalRestoreSnapshot else { externalRestoreMessage="预览快照缺失，没有执行"; return }
            // Per-window permits: one undeterminable window is blocked on its own instead of aborting the batch.
            let split=MoveScope.partition(plan,snapshot:snapshot) { entry in try self.singlePermit(entry,snapshot:snapshot) }
            plan=split.plan; permits=split.permits
        }
        let mover=permits.isEmpty ? nil : makeControlledMover(permits)
        let report=ManualRestorer.execute(plan,windows:windows,spaces:mover,approved:true,polls:8,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))},persist:{ journal in
            if let url=journalURL { try RestoreJournalStore.update(journal,at:url) }
            else {
                guard let directory=self.guidedDirectory else { throw LayoutError.unsupported }
                journalURL=try RestoreJournalStore.create(journal,in:directory.appendingPathComponent("transactions",isDirectory:true))
            }
        })
        if let journal=report.journal { lastRestoreJournal=journal; lastRestoreJournalURL=journalURL; lastRestorePermits=permits }
        externalRestoreResults=report.results
        let verified=report.results.filter{$0.outcome == .verified}.count
        externalRestoreMessage="\(verified) 项位置、大小和桌面通过回读。请逐项检查结果。" + (report.persistenceIssues.isEmpty ? "" : "操作日志更新失败，撤销记录可能不完整。")
    }
    func undoExternalRestore() {
        guard !restoring,let journal=lastRestoreJournal,journal.canUndo,let url=lastRestoreJournalURL else { return }
        let alert=NSAlert(); alert.messageText="撤销上次窗口恢复？"
        alert.informativeText="恢复本次操作前的桌面、位置与大小。仅处理身份、桌面和位置仍与操作结果一致的窗口；之后手动移动过的窗口会跳过。换屏、重启或桌面变化后禁止撤销。"
        alert.addButton(withTitle:"确认撤销"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        refreshAuthorization(); guard trusted else { externalRestoreMessage=accessState.guidance; return }
        restoring=true; windows.writesApproved=true
        defer { restoring=false; windows.writesApproved=false; externalRestorePlan=nil }
        let report=ManualRestorer.undo(journal,windows:windows,spaces:lastRestorePermits.isEmpty ? nil : makeControlledMover(lastRestorePermits),approved:true,polls:8,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))},persist:{try RestoreJournalStore.update($0,at:url)})
        lastRestoreJournal=report.journal; externalRestoreResults=report.results
        externalRestoreMessage="撤销已结束，\(report.results.filter{$0.outcome == .verified}.count) 项原位置通过回读。" + (report.persistenceIssues.isEmpty ? "请检查逐项结果。" : "日志更新失败，请检查实际窗口。")
        quickResults=[:]; quickMessage=externalRestoreMessage
        if quickRecord != nil,let after=try? windows.snapshot() { quickSnapshot=after; quickChoices=[:]; replanQuick(); quickMessage=externalRestoreMessage }
    }
    /// Per-window cross-Space approvals for the given ready plan entries (shared by manual restore and the self-test).
    func singlePermit(_ entry: PlanEntry,snapshot: Snapshot) throws -> SpaceMovePermit {
        guard let window=entry.window,let space=entry.targetSpace,let display=entry.targetDisplay else { throw LayoutError.readbackUnavailable }
        return try SpaceMovePermit(window:window,targetSpace:space,targetDisplay:display,snapshot:snapshot,tokenPinned:entry.tokenPinned==true)
    }
    func crossSpacePermits(_ entries: [PlanEntry],snapshot: Snapshot) throws -> [SpaceMovePermit] {
        try entries.filter{$0.window?.spaceIDs != [$0.targetSpace ?? 0]}.map { entry in
            guard let window=entry.window,let space=entry.targetSpace,let display=entry.targetDisplay else { throw LayoutError.readbackUnavailable }
            return try SpaceMovePermit(window:window,targetSpace:space,targetDisplay:display,snapshot:snapshot,tokenPinned:entry.tokenPinned==true)
        }
    }
    func frameDescription(_ frame: Rect?) -> String {
        guard let frame else { return "无可靠坐标" }
        return "位置 (\(Int(frame.x)), \(Int(frame.y))) · 大小 \(Int(frame.width)) × \(Int(frame.height))"
    }
}

struct ExternalRestoreSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("高级：按窗口组手动对应桌面").font(.title2.bold())
            Text("先把保存的窗口组对应到当前外屏的普通桌面。默认只调整同桌面位置与大小。跨桌面需本次单独启用、确认，并逐窗验证。窗口标题仅在本机显示和保存。")
                .foregroundStyle(.secondary)
            Toggle("本次启用跨桌面恢复（仅在已验证的系统版本可用）",isOn:$model.externalCrossSpaceAllowed)
                .disabled(!model.crossSpaceEnabled)
                .onChange(of:model.externalCrossSpaceAllowed) { model.rebuildExternalPreview() }
            if !model.crossSpaceEnabled { Text(model.crossSpaceSupport.detail).font(.caption) }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(Array(model.restoreGroups.enumerated()),id:\.element) { index,group in
                        VStack(alignment:.leading,spacing:6) {
                            let titles=model.externalRestoreRecord?.profile.windows.filter{$0.desktopLabel==group}.map{$0.selector.title.isEmpty ? $0.selector.bundleID : $0.selector.title} ?? []
                            Text("保存窗口组 \(index+1)：\(titles.joined(separator:"、"))").font(.headline)
                            Picker("对应当前桌面",selection:Binding<UInt64>(get:{model.externalGroupSpaces[group] ?? 0},set:{ value in
                                if value==0 { model.externalGroupSpaces.removeValue(forKey:group) } else { model.externalGroupSpaces[group]=value }
                                model.rebuildExternalPreview()
                            })) {
                                Text("尚未选择").tag(UInt64(0))
                                ForEach(Array(model.restoreDesktops.enumerated()),id:\.element.id) { offset,space in
                                    Text("本次外屏桌面 \(offset+1)\(space.active ? "（当前）" : "")").tag(space.id)
                                }
                            }
                        }.padding(10).background(.quaternary).cornerRadius(8)
                    }
                    if model.restoreGroups.count>model.restoreDesktops.count {
                        Text("保存的窗口组多于当前普通桌面。不会自动创建桌面或合并不同窗口组。").foregroundStyle(.orange)
                    }
                    if let plan=model.externalRestorePlan {
                        ForEach(Array(plan.entries.enumerated()),id:\.offset) { _,entry in
                            VStack(alignment:.leading,spacing:5) {
                                Text("\(entry.saved.selector.title.isEmpty ? entry.saved.selector.bundleID : entry.saved.selector.title) · \(entry.status == .ready ? "可以恢复" : (entry.status == .skipped ? "跳过" : "暂不能恢复"))").bold()
                                Text(entry.reason).font(.callout)
                                if entry.window != nil { Text("现在：\(model.frameDescription(entry.window?.frame))").font(.caption) }
                                if entry.targetFrame != nil { Text("目标：\(model.frameDescription(entry.targetFrame))").font(.caption) }
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary).cornerRadius(8)
                        }
                    }
                    ForEach(Array(model.externalRestoreResults.enumerated()),id:\.offset) { _,result in
                        Text("\(result.title)：\(result.detail)").font(.callout)
                    }
                }
            }
            Text(model.externalRestoreMessage).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("重新读取预览") { model.prepareExternalRestore() }
                Button("撤销上次恢复") { model.undoExternalRestore() }.disabled(model.lastRestoreJournal?.canUndo != true || !model.trusted)
                Spacer()
                Button("确认恢复可执行项目") { model.executeExternalRestore() }.buttonStyle(.borderedProminent)
                    .disabled(model.externalRestorePlan?.entries.contains{$0.status == .ready} != true || !model.trusted)
                Button("关闭") { dismiss() }
            }
        }.padding(24).frame(width:740,height:640).disabled(model.restoring)
    }
}
