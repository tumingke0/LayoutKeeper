// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit

import LayoutCore
import MacAdapters

extension Model {
    func undoExternalRestore() {
        guard !restoring,let journal=lastRestoreJournal,journal.canUndo,let url=lastRestoreJournalURL else { return }
        let alert=NSAlert(); alert.messageText=lk("撤销上次窗口恢复？")
        alert.informativeText=lk("恢复本次操作前的桌面、位置与大小。仅处理身份、桌面和位置仍与操作结果一致的窗口；之后手动移动过的窗口会跳过。换屏、重启或桌面变化后禁止撤销。")
        alert.addButton(withTitle:lk("确认撤销")); alert.addButton(withTitle:lk("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        refreshAuthorization(); guard trusted else { externalRestoreMessage=accessState.guidance; return }
        restoring=true; windows.writesApproved=true
        defer { restoring=false; windows.writesApproved=false }
        let report=ManualRestorer.undo(journal,windows:windows,spaces:lastRestorePermits.isEmpty ? nil : makeControlledMover(lastRestorePermits),approved:true,polls:8,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))},persist:{try RestoreJournalStore.update($0,at:url)})
        lastRestoreJournal=report.journal; externalRestoreResults=report.results
        externalRestoreMessage=lk("撤销已结束，%@ 项原位置通过回读。", "\(report.results.filter{$0.outcome == .verified}.count)") + (report.persistenceIssues.isEmpty ? lk("请检查逐项结果。") : lk("日志更新失败，请检查实际窗口。"))
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
}

