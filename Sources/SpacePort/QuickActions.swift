// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

enum RestoreTrigger { case manual, automatic }
struct DirectRestoreOutcome {
    var restored=0, attempted=0, needsConfirmation=0, skippedAuto=0
    var error: String?
    var nothingToDo: Bool { error == nil && attempted == 0 }
    var failed: Int { attempted-restored }
}
enum SaveOutcome { case saved(count: Int, replaced: Bool), cancelled, failed(String) }

/// Actions shared by the menu bar, global hotkeys, the main window and the reconnect flow.
extension Model {
    var currentMonitorName: String? { currentExternalMonitor.map{ monitorPreferences.displayName($0.identity) } }
    var busy: Bool { restoring || selfTestRunning || checkingCapture }
    func menuState(optionHeld: Bool) -> MenuState {
        var s=MenuState()
        s.monitorName=currentMonitorName
        s.windowCount=externalRecord?.profile.windows.count; s.savedAt=externalRecord?.savedAt
        s.trusted=trusted; s.busy=busy; s.canUndo=lastRestoreJournal?.canUndo == true
        s.globalMode=autoRestoreMode
        s.monitorChoice=currentExternalMonitor.flatMap{ monitorPreferences.restore($0.identity.key) }
        if let key=currentExternalMonitor?.identity.key {
            let list=selectedScreenKey==key ? namedLayouts : (screenLibrary?.namedLayouts(key) ?? [])
            s.layouts=list.map { MenuLayout(name:$0.name,active:$0.isActive) }
        }
        s.pausedUntil=pausedUntil; s.now=Date(); s.hotkeys=hotkeySettings; s.optionHeld=optionHeld
        return s
    }
    /// Why save/restore can't run right now (nil when it can).
    func quickBlocker(needsLayout: Bool) -> String? {
        if currentExternalMonitor == nil { return externalMonitors.count>1 ? "目前只支持一块外接屏" : "未连接外接屏" }
        if !trusted { return "需要辅助功能权限" }
        if needsLayout && externalRecord == nil { return "这块屏幕尚未保存布局" }
        if busy { return "正在处理上一个操作" }
        return nil
    }
    /// Menu / hotkey save: no dialog. Overwriting keeps `.previous.json` exactly as before.
    func quickSave() {
        refreshExternalMonitor()
        if let why=quickBlocker(needsLayout:false) { showToast?(Toast(icon:"exclamationmark.triangle.fill",tone:.warning,title:"没有保存",detail:why)); return }
        switch saveExternalLayout(confirmOverwrite:false) {
        case .saved(let count,let replaced):
            showToast?(Toast(icon:"checkmark.circle.fill",tone:.success,title:"已保存 \(count) 个窗口",detail:replaced ? "旧版本已存入历史" : nil))
        case .failed(let why): showToast?(Toast(icon:"exclamationmark.triangle.fill",tone:.warning,title:"没有保存",detail:why,duration:4))
        case .cancelled: break
        }
        requestLiveCheck?()
    }
    /// Plans and immediately executes only the uniquely matched ("ready") windows; ambiguous ones are never moved.
    /// Automatic mode additionally skips windows coming from another screen or needing any confirmation.
    @discardableResult func directRestore(_ trigger: RestoreTrigger) -> DirectRestoreOutcome {
        var outcome=DirectRestoreOutcome()
        guard prepareQuickRestore(),let plan=quickPlan else { outcome.error=quickMessage.isEmpty ? "无法生成恢复计划" : quickMessage; return outcome }
        outcome.needsConfirmation=plan.items.filter{$0.state == .needsConfirmation}.count
        let runnable=trigger == .automatic ? QuickRestorePlanner.autoSubset(plan).entries.count : plan.readyCount
        outcome.skippedAuto=plan.readyCount-runnable
        guard runnable>0 else { return outcome }
        let result=executeQuickRestore(autoOnly:trigger == .automatic)
        outcome.restored=result.verified; outcome.attempted=result.attempted
        if result.attempted>0 { lastRestoreSummary=RestoreSummary(at:Date(),restored:result.verified,needsConfirmation:outcome.needsConfirmation,failed:result.attempted-result.verified) }
        requestLiveCheck?()
        return outcome
    }
    func restoreToast(_ o: DirectRestoreOutcome,trigger: RestoreTrigger) -> Toast? {
        let view=Toast.Action(title:"查看") { [weak self] in self?.openPreviewPanel?(false) }
        if let error=o.error {
            if trigger == .automatic && externalRecord == nil { return nil }
            return Toast(icon:"exclamationmark.triangle.fill",tone:.warning,title:trigger == .automatic ? "没有自动恢复" : "没有恢复",detail:error,duration:5)
        }
        if o.nothingToDo {
            if o.needsConfirmation>0 { return Toast(icon:"questionmark.circle.fill",tone:.warning,title:"\(o.needsConfirmation) 个窗口需要确认",detail:"无法唯一确认，没有移动",actions:[view],duration:trigger == .automatic ? 7 : 5) }
            if o.skippedAuto>0 { return Toast(icon:"info.circle.fill",tone:.neutral,title:"\(o.skippedAuto) 个窗口在另一块屏幕上",detail:"自动恢复不会移动它们，可手动恢复",actions:[view],duration:7) }
            // Automatic: nothing moved and nothing needs you → stay silent. Manual: always answer.
            return trigger == .automatic ? nil : Toast(icon:"checkmark.circle.fill",tone:.success,title:"布局已是保存的样子")
        }
        var title="已恢复 \(o.restored) 个窗口"
        if o.needsConfirmation>0 { title+=" · \(o.needsConfirmation) 个需确认" }
        let detail: String?=o.failed>0 ? "\(o.failed) 个未通过，已回滚" : (o.skippedAuto>0 ? "\(o.skippedAuto) 个在另一块屏幕上的窗口没有自动移动" : nil)
        var actions=[Toast.Action]()
        if lastRestoreJournal?.canUndo == true { actions.append(Toast.Action(title:"撤销") { [weak self] in NSApp.activate(ignoringOtherApps:true); self?.undoExternalRestore(); self?.requestLiveCheck?() }) }
        actions.append(view)
        return Toast(icon:o.failed>0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill",tone:o.failed>0 || o.needsConfirmation>0 ? .warning : .success,title:title,detail:detail,actions:actions,duration:trigger == .automatic ? 7 : 5)
    }
    func quickRestore() {
        refreshExternalMonitor()
        if let why=quickBlocker(needsLayout:true) { showToast?(Toast(icon:"exclamationmark.triangle.fill",tone:.warning,title:"没有恢复",detail:why)); return }
        if let toast=restoreToast(directRestore(.manual),trigger:.manual) { showToast?(toast) }
    }
    func quickUndo() {
        guard lastRestoreJournal?.canUndo == true else { showToast?(Toast(icon:"info.circle.fill",tone:.neutral,title:"没有可撤销的恢复")); return }
        NSApp.activate(ignoringOtherApps:true)
        undoExternalRestore()
        requestLiveCheck?()
    }
    var mainState: MainWindowState {
        let key=liveKey
        return MainWindowState.derive(hasMonitor:currentExternalMonitor != nil,trusted:trusted,hasLayout:externalRecord != nil,plan:key != nil && key == livePlanKey ? livePlan : nil)
    }
    var liveKey: String? {
        guard let m=currentExternalMonitor,let r=externalRecord else { return nil }
        return "\(m.identity.key)|\(m.runtimeDisplayToken)|\(r.savedAt.timeIntervalSince1970)"
    }
    /// Read-only: scans with the separate status reader and plans; never writes or moves anything.
    func refreshLiveState() {
        guard emptyWindowTrial == nil,trialConfigurationError.isEmpty,!busy,trusted,let monitor=currentExternalMonitor,let record=externalRecord,let key=liveKey else { return }
        do {
            let snapshot=try statusWindows.scan(selectedDisplayToken:monitor.runtimeDisplayToken,inspectionBudget:2)
            livePlan=try QuickRestorePlanner.plan(record:record,monitor:monitor.identity,displayToken:monitor.runtimeDisplayToken,snapshot:snapshot,allowCrossSpace:crossSpaceEnabled)
            livePlanKey=key
        } catch { livePlan=nil; livePlanKey=nil }
    }
}
