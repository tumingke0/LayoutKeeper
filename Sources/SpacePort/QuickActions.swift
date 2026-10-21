// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

enum RestoreTrigger { case manual, automatic }
struct DirectRestoreOutcome {
    var restored=0, attempted=0, needsConfirmation=0, skippedAuto=0
    var error: String?
    var failures: [RestoreFailure]=[]
    /// Which windows (tokens) this restore verified or failed; lets multi-step attaches count each window once.
    var tally=RestoreTally()
    /// Per app: saved windows reported as closed ("保存的 2 个窗口已关闭，现在开着的是另外 1 个窗口").
    var staleText: [String]=[]
    /// Groups left where they are because there is no free desk for them, and how many desks that needs.
    var unplacedGroups=0, missingDesktops=0
    /// Strip positions waiting for a desktop ("3、4"), and what to say about the strip (order changed, desk deleted).
    var unplacedPositions: [Int]=[]
    var stripNotices: [String]=[]
    var nothingToDo: Bool { error == nil && attempted == 0 }
    var failed: Int { attempted-restored }
}
enum SaveOutcome { case saved(count: Int, replaced: Bool), cancelled, failed(String) }

/// Actions shared by the menu bar, global hotkeys, the main window and the reconnect flow.
extension Model {
    var currentMonitorName: String? { currentExternalMonitor.map{ monitorPreferences.displayName($0.identity) } }
    var busy: Bool { restoring || selfTestRunning || checkingCapture || arrangementPreview != nil }
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
        s.pendingNotice=undeliveredNotice?.title; s.pendingNoticeDetail=undeliveredNotice?.detail
        s.arrangement=arrangementMenu()
        return s
    }
    /// Why save/restore can't run right now (nil when it can).
    func quickBlocker(needsLayout: Bool) -> String? {
        if currentExternalMonitor == nil { return externalMonitors.count>1 ? lk("目前只支持一块外接屏") : lk("未连接外接屏") }
        if !trusted { return lk("需要辅助功能权限") }
        if needsLayout && externalRecord == nil && currentExternalMonitor.flatMap({ activeArrival(for:$0.identity,saved:nil) }) == nil { return lk("这块屏幕尚未保存布局") }
        if busy { return lk("正在处理上一个操作") }
        return nil
    }
    /// Menu / hotkey save: no dialog. Overwriting keeps `.previous.json` exactly as before.
    func quickSave() {
        refreshExternalMonitor()
        if let why=quickBlocker(needsLayout:false) { notify?(UserNotice(title:lk("没有保存"),detail:why)); return }
        switch saveExternalLayout(confirmOverwrite:false) {
        case .saved(let count,let replaced):
            notify?(UserNotice(title:lk("已保存 %@ 个窗口", "\(count)"),detail:replaced ? lk("旧版本已存入历史") : nil))
        case .failed(let why): notify?(UserNotice(title:lk("没有保存"),detail:why,duration:4))
        case .cancelled: break
        }
        requestLiveCheck?()
    }
    /// Plans and immediately executes only the uniquely matched ("ready") windows; ambiguous ones are never moved.
    /// Automatic mode additionally skips windows coming from another screen or needing any confirmation.
    @discardableResult func directRestore(_ trigger: RestoreTrigger) -> DirectRestoreOutcome {
        var outcome=DirectRestoreOutcome()
        let tag=trigger == .automatic ? "auto" : "manual"
        logRestore("directRestore \(tag): start")
        lastRestoreTrigger=trigger
        if trigger == .manual { logSession("manual restore") }
        guard prepareQuickRestore(),var plan=quickPlan else { logRestore("directRestore \(tag): exit — no plan: \(quickMessage.isEmpty ? "-" : String(quickMessage.prefix(160)))"); outcome.error=quickMessage.isEmpty ? lk("无法生成恢复计划") : quickMessage; logRestore("restore \(trigger == .automatic ? "auto" : "manual") no plan"); return outcome }
        if trigger == .automatic,let record=quickRecord,let snap=quickSnapshot,let display=quickDisplayToken {
            let q=QuickRestorePlanner.quietAlreadyInPlace(plan,record:record,snapshot:snap,displayToken:display,browserProfiles:ChromeProfiles.load()?.map(snap.windows) ?? [:])
            if !q.quieted.isEmpty || !q.missing.isEmpty || !q.stale.isEmpty {
                plan=q.plan; quickPlan=plan
                if !q.quieted.isEmpty || !q.missing.isEmpty { logRestore("directRestore auto: needsConfirmation→alreadyInPlace \(q.quieted) missing \(q.missing) (same title/document/profile window already on the saved desk with saved geometry)") }
                if !q.stale.isEmpty { logRestore("directRestore auto: needsConfirmation→stale(closed) \(q.stale) (no open window of the app shares title, document or Chrome profile)") }
            }
        }
        outcome.staleText=plan.staleSummary{ Self.appName($0) }
        outcome.missingDesktops=plan.missingDesktops; outcome.unplacedGroups=plan.unplacedGroups.count
        outcome.unplacedPositions=plan.unplacedPositions; outcome.stripNotices=plan.stripNotices
        logRestoreLines(RestoreLog.deskMapLines(trigger:tag,plan:plan))
        logRestore(RestoreLog.planSummary(trigger:tag,plan:plan))
        logPlanDetail(trigger:tag,plan:plan,record:quickRecord,snapshot:quickSnapshot,displayToken:quickDisplayToken)
        if !quickMessage.isEmpty { logRestore("directRestore \(tag): planner message: \(quickMessage.prefix(200))") }
        defer { if let plan=quickPlan { noteSharedPlan(plan) } }
        outcome.needsConfirmation=plan.items.filter{$0.state == .needsConfirmation}.count
        let runnable=trigger == .automatic ? QuickRestorePlanner.autoSubset(plan).entries.count : plan.readyCount
        outcome.skippedAuto=plan.readyCount-runnable
        guard runnable>0 else {
            let waiting=plan.items.filter{$0.state == .needsConfirmation}.map{"\($0.bundleID)"}.joined(separator:",")
            logRestore("restore \(tag) nothing-to-run skippedAuto=\(outcome.skippedAuto) ready=\(plan.readyCount) states=\(Dictionary(grouping:plan.items,by:\.state.rawValue).mapValues(\.count))")
            for i in plan.items where i.state == .ready && trigger == .automatic { logRestore("directRestore auto: not auto-run #\(i.savedIndex) \(i.bundleID) because \(RestoreLog.autoReason(i))") }
            if !waiting.isEmpty { logRestore("restore \(trigger == .automatic ? "auto" : "manual") nothing-to-do needsConfirmation=\(outcome.needsConfirmation) [\(waiting)]") }
            return outcome
        }
        logRestore("directRestore \(tag): executing runnable=\(runnable) of ready=\(plan.readyCount)")
        let result=executeQuickRestore(autoOnly:trigger == .automatic)
        logRestore("directRestore \(tag): done verified=\(result.verified) attempted=\(result.attempted) failures=\(lastRestoreFailures.map{ "\($0.bundleID):\($0.reason.rawValue)" })")
        outcome.restored=result.verified; outcome.attempted=result.attempted; outcome.failures=lastRestoreFailures
        if result.attempted>0,let entries=lastRestoreJournal?.entries {
            let ok=Set(entries.filter{ $0.state == .verified }.map(\.before.token))
            outcome.tally.add(verified:ok,failed:Set(entries.filter{ ![.verified,.unchanged].contains($0.state) }.map(\.before.token)).subtracting(ok))
        }
        if result.attempted>0 { lastRestoreSummary=RestoreSummary(at:Date(),restored:result.verified,needsConfirmation:outcome.needsConfirmation,failed:result.attempted-result.verified) }
        requestLiveCheck?()
        return outcome
    }
    /// "3、4" for strip positions.
    static func positionList(_ p: [Int]) -> String { p.map(String.init).joined(separator:lk("、")) }
    func restoreNotice(_ o: DirectRestoreOutcome,trigger: RestoreTrigger) -> UserNotice? {
        // Clicking a result notice (or its 「查看」 button) opens the preview / results panel of this restore.
        let openResult: () -> Void={ [weak self] in self?.openPreviewPanel?(false) }
        let view=UserNotice.Action(.view,run:openResult)
        let retry=UserNotice.Action(.retry) { [weak self] in self?.quickRestore() }
        let restoreNow=UserNotice.Action(.restoreNow) { [weak self] in self?.quickRestore() }
        // Automatic restores that leave something undone stay in Notification Center until dismissed, so the problem is not missed.
        let attention: TimeInterval=trigger == .automatic ? 0 : 8
        if let error=o.error {
            if trigger == .automatic && externalRecord == nil { return nil }
            return UserNotice(title:trigger == .automatic ? lk("没有自动恢复") : lk("没有恢复"),detail:error,duration:5)
        }
        // Closed saved windows and groups without a desk, appended to whatever the notice says.
        var extra=o.staleText
        if o.unplacedGroups>0 && !sharedModeActive { extra.append(lk("还缺 %@ 个桌面：第 %@ 个桌面的窗口没有移动，补好桌面后再恢复一次", "\(o.missingDesktops)", Self.positionList(o.unplacedPositions))) }
        let extraText=extra.isEmpty ? nil : extra.joined(separator:lk("；"))+(o.staleText.isEmpty ? "" : lk("。重新保存一次布局后就不再提示。"))
        func join(_ a: String?,_ b: String?) -> String? { [a,b].compactMap{ $0 }.isEmpty ? nil : [a,b].compactMap{ $0 }.joined(separator:"\n") }
        if o.nothingToDo {
            if o.failures.isEmpty && o.needsConfirmation == 0 && o.skippedAuto == 0,let extraText {
                return UserNotice(title:o.staleText.isEmpty ? lk("有窗口没有移动") : lk("保存的部分窗口已关闭"),detail:extraText,actions:[view],duration:attention,open:openResult)
            }
            if !o.failures.isEmpty { return UserNotice(title:lk("没有恢复窗口"),detail:Self.failureText(o.failures),actions:[retry,view],duration:attention,open:openResult) }
            if o.needsConfirmation>0 { return UserNotice(title:lk("%@ 个窗口需要确认", "\(o.needsConfirmation)"),detail:lk("无法唯一确认，没有移动"),actions:[view],duration:attention,open:openResult) }
            if o.skippedAuto>0 { return UserNotice(title:lk("%@ 个窗口没有自动恢复", "\(o.skippedAuto)"),detail:lk("无法唯一确认这些窗口，点「恢复布局」可以预览后手动恢复"),actions:[restoreNow,view],duration:attention,open:openResult) }
            // Automatic: nothing moved and nothing needs you → stay silent. Manual: always answer.
            return trigger == .automatic ? nil : UserNotice(title:lk("布局已是保存的样子"))
        }
        let extraWithStrip=o.stripNotices.isEmpty ? extraText : join(o.stripNotices.joined(separator:lk("；")),extraText)
        var title=lk("已恢复 %@ 个窗口", "\(o.restored)")
        if o.needsConfirmation>0 { title+=lk(" · %@ 个需确认", "\(o.needsConfirmation)") }
        let detail: String? = join(!o.failures.isEmpty ? Self.failureText(o.failures) : (o.failed>0 ? lk("%@ 个未通过，已回滚", "\(o.failed)") : (o.skippedAuto>0 ? lk("%@ 个窗口无法唯一确认，没有自动移动", "\(o.skippedAuto)") : nil)),extraWithStrip)
        var actions=[UserNotice.Action]()
        if !o.failures.isEmpty { actions.append(retry) }
        if lastRestoreJournal?.canUndo == true { actions.append(UserNotice.Action(.undo) { [weak self] in NSApp.activate(ignoringOtherApps:true); self?.undoExternalRestore(); self?.requestLiveCheck?() }) }
        actions.append(view)
        let problem=o.failed>0 || !o.failures.isEmpty
        return UserNotice(title:title,detail:detail,actions:actions,
                     duration:problem || o.needsConfirmation>0 || o.skippedAuto>0 ? attention : (trigger == .automatic ? 7 : 5),open:openResult)
    }
    /// "Antigravity 没有响应，已跳过；Chrome 的窗口已改变，没有移动" — app names, never window titles.
    static func failureText(_ failures: [RestoreFailure]) -> String {
        var seen=Set<String>()
        let parts=failures.filter{ seen.insert($0.bundleID+$0.reason.rawValue).inserted }.prefix(3).map { f -> String in
            let name=appName(f.bundleID)
            switch f.reason {
            case .notResponding: return lk("%@ 没有响应，已跳过", name)
            case .changed: return lk("%@ 的窗口刚刚改变，没有移动", name)
            case .failed: return lk("%@ 的窗口没能移到位，已放回原处", name)
            }
        }
        let more=failures.count>parts.count && seen.count>3 ? lk("等") : ""
        return parts.joined(separator:lk("；"))+more+lk("。可以点「重试」。")
    }
    static func appName(_ bundleID: String) -> String {
        if let name=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first?.localizedName { return name }
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) { return FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:"") }
        return bundleID
    }
    func quickRestore() {
        refreshExternalMonitor()
        if let why=quickBlocker(needsLayout:true) { notify?(UserNotice(title:lk("没有恢复"),detail:why)); return }
        if let notice=restoreNotice(directRestore(.manual),trigger:.manual) { notify?(notice) }
    }
    func quickUndo() {
        guard lastRestoreJournal?.canUndo == true else { notify?(UserNotice(title:lk("没有可撤销的恢复"))); return }
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
    static var loggedLaunchPlan=false
    /// Read-only: scans with the separate status reader and plans; never writes or moves anything.
    func refreshLiveState() {
        guard emptyWindowTrial == nil,trialConfigurationError.isEmpty,!busy,trusted,let monitor=currentExternalMonitor,let record=externalRecord,let key=liveKey else { return }
        do {
            let snapshot=try statusWindows.scan(selectedDisplayToken:monitor.runtimeDisplayToken,inspectionBudget:2)
            // During an attach the status reflects the layout the attach restores from (composed by the restore itself).
            let effective=activeArrival(for:monitor.identity,saved:record)?.effective
            livePlan=try QuickRestorePlanner.plan(record:effective?.record ?? record,monitor:monitor.identity,displayToken:monitor.runtimeDisplayToken,snapshot:snapshot,allowCrossSpace:crossSpaceEnabled,browserProfiles:ChromeProfiles.load()?.map(snapshot.windows) ?? [:],context:effective?.context)
            livePlanKey=key
            // Once per launch: log the read-only plan (Chrome profile resolution + auto eligibility per window).
            if !Self.loggedLaunchPlan,let plan=livePlan { Self.loggedLaunchPlan=true; logPlanDetail(trigger:"launch-dry",plan:plan,record:record,snapshot:snapshot,displayToken:monitor.runtimeDisplayToken) }
        } catch { livePlan=nil; livePlanKey=nil }
    }
}
