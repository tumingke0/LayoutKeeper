// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

/// A shared-mode notice. Posted as a notification and kept in the model until dismissed or resolved.
struct SharedNotice: Equatable {
    enum Kind: Equatable { case missingSpaces(Int), separateSpacesOff, multipleMonitors }
    var kind: Kind
    /// Set when the experimental automatic add/remove gave up; shown above the manual steps.
    var autoFailure: String?=nil
    var title: String {
        switch kind {
        case .missingSpaces(let n): return lk("外接屏少 %@ 个桌面", "\(n)")
        case .separateSpacesOff: return lk("「显示器具有单独的空间」已关闭")
        case .multipleMonitors: return lk("接了多块外接屏，已按每块屏单独记")
        }
    }
    var detail: String {
        let prefix=autoFailure.map{ lk("自动操作没完成（%@），已停下。", "\($0)") } ?? ""
        return prefix+manualDetail
    }
    var manualDetail: String {
        switch kind {
        case .missingSpaces(let n): return lk("多出来的窗口先放在最后一个桌面。打开调度中心，在顶部按「+」补 %@ 个桌面，补好后会自动再恢复一次。", "\(n)")
        case .separateSpacesOff: return lk("共用模式需要每块屏有自己的桌面。请在「系统设置 → 桌面与程序坞 → 调度中心」打开它，注销后生效。")
        case .multipleMonitors: return lk("共用模式只在接一块外接屏时生效。拔到只剩一块后会自动切回共用布局。")
        }
    }
}

enum SeparateSpaces {
    /// `defaults read com.apple.spaces spans-displays`: 1 means "Displays have separate Spaces" is OFF. Read only.
    static var enabled: Bool { !(UserDefaults(suiteName:"com.apple.spaces")?.bool(forKey:"spans-displays") ?? false) }
}

enum MissionControl {
    static func open() {
        let url=URL(fileURLWithPath:"/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
    }
}

extension Model {
    var sharedModeActive: Bool { currentExternalMonitor?.identity.isSharedExternal == true }
    func sharedNoticeContent(_ notice: SharedNotice) -> UserNotice {
        var actions=[UserNotice.Action]()
        switch notice.kind {
        case .missingSpaces: actions.append(UserNotice.Action(.openMissionControl) { MissionControl.open() })
        case .separateSpacesOff: actions.append(UserNotice.Action(.openSettings) { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Desktop-Settings.extension")!) })
        case .multipleMonitors: break
        }
        return UserNotice(title:notice.title,detail:notice.detail,actions:actions,duration:0,onDismiss:{ [weak self] in
            if self?.sharedNotice == notice { self?.sharedNotice=nil }
        })
    }
    func postSharedNotice(_ notice: SharedNotice) {
        guard sharedNotice != notice else { return }
        sharedNotice=notice
        notify?(sharedNoticeContent(notice))
    }
    /// Called when 布局模式 changes. Switching to shared mode seeds the shared layout once; per-monitor files are never changed.
    func layoutModeChanged() {
        MonitorRecognition.layoutMode=layoutMode
        sharedNotice=nil; pendingSpacesNeeded=nil
        guard !RenderMode.snapshot else { return }
        if layoutMode == .sharedExternal {
            let physical=MonitorRecognition.physicalExternalMonitors()
            if let library=screenLibrary,let source=try? SharedLayout.seed(library:library,preferredKey:physical.count==1 ? physical[0].identity.key : nil) {
                let name=savedScreens.first{ $0.key==source }?.name ?? lk("外接屏")
                notify?(UserNotice(title:lk("已切换为共用一套"),detail:lk("用「%@」现在的布局作为共用布局，原来各屏的记录都保留着。", "\(name)"),duration:6))
            }
            if !SeparateSpaces.enabled { postSharedNotice(SharedNotice(kind:.separateSpacesOff)) }
            else if physical.count>1 { postSharedNotice(SharedNotice(kind:.multipleMonitors)) }
        }
        selectedScreenKey=nil; previewVersion=nil; previewRecord=nil
        refreshExternalMonitor()
    }
    /// After a shared-mode restore: remember how many Spaces are needed so adding them triggers another restore.
    func noteSharedPlan(_ plan: QuickRestorePlan) {
        guard sharedModeActive else { logRestore("auto-spaces: not shared mode, no add/remove check (needed=\(plan.desktopsNeeded) have=\(plan.desktopsNow))"); return }
        logRestore("auto-spaces: shared plan needed=\(plan.desktopsNeeded) have=\(plan.desktopsNow) missing=\(plan.missingDesktops)")
        if plan.missingDesktops>0 {
            pendingSpacesNeeded=plan.desktopsNeeded
            if !tryAutoAddSpaces(needed:plan.desktopsNeeded,available:plan.desktopsNeeded-plan.missingDesktops) {
                postSharedNotice(SharedNotice(kind:.missingSpaces(plan.missingDesktops)))
            }
        } else {
            pendingSpacesNeeded=nil
            if case .missingSpaces? = sharedNotice?.kind { sharedNotice=nil }
        }
    }
}

extension Model {
    var builtInDisplayToken: String? { MacEnvironment.displays().first{ $0.role == .builtIn }?.token }
    var externalDisplayToken: String? { let e=MacEnvironment.displays().filter{ $0.role == .external }; return e.count==1 ? e[0].token : nil }
    /// 实验：自动补桌面. Returns true when a run was started (the notice is then shown only if it fails).
    func tryAutoAddSpaces(needed: Int,available: Int) -> Bool {
        guard !RenderMode.snapshot else { return false }
        guard trusted else { logRestore("auto-add spaces: skipped — no Accessibility permission (needed=\(needed) have=\(available))"); return false }
        guard SeparateSpaces.enabled else { logRestore("auto-add spaces: skipped — Displays have separate Spaces is off"); return false }
        guard let token=externalDisplayToken else { logRestore("auto-add spaces: skipped — not exactly one external display"); return false }
        guard let all=try? spaces.spaces(displays:MacEnvironment.displays()) else { logRestore("auto-add spaces: skipped — Spaces unreadable"); return false }
        let planned=AutoSpaces.planAdd(enabled:autoAddSpaces,needed:needed,available:available,spaces:all)
        guard case .success(let count)=planned else {
            if case .failure(let e)=planned { logRestore("auto-add spaces: skipped — \(e.blocker) (enabled=\(autoAddSpaces) needed=\(needed) have=\(available) running=\(autoSpaces.running))") }
            return false
        }
        let missing=needed-available
        let followUp=autoSpacesFollowUp, trigger=lastRestoreTrigger
        autoSpacesStartedByRestore=true
        logRestore("auto-add spaces: start count=\(count) needed=\(needed) available=\(available) followUp=\(followUp == nil ? "own restore (\(trigger))" : "attach session")")
        autoSpaces.add(count:count,token:token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let n):
                self.logRestore("auto-add spaces: added \(n)")
                self.pendingSpacesNeeded=nil
                if case .missingSpaces? = self.sharedNotice?.kind { self.sharedNotice=nil }
                self.notify?(UserNotice(title:lk("已自动补了 %@ 个桌面", "\(n)"),detail:lk("正在按桌面顺序恢复窗口。"),duration:4))
                if let followUp { followUp(.success(n)); return }
                // Not part of an attach session (e.g. after a manual restore): restore again with the same trigger.
                let outcome=self.directRestore(trigger)
                if let notice=self.restoreNotice(outcome,trigger:trigger) { self.notify?(notice) }
            case .failure(let e):
                NSLog("LayoutKeeper auto add Spaces stopped: %@",e.description)
                self.logRestore("auto-add spaces: failed (\(e.description.prefix(80)))")
                var notice=SharedNotice(kind:.missingSpaces(missing)); notice.autoFailure=e.description
                self.postSharedNotice(notice)
                followUp?(.failure(AutoSpacesFailure(description:e.description)))
            }
        }
        return true
    }
    /// 实验：拔屏后自动删掉挪到内置屏上的空桌面. Returns true when a run was started.
    func tryAutoRemoveSpaces(before: SpaceCensus,after: SpaceCensus) -> Bool {
        guard !RenderMode.snapshot else { return false }
        // 0.6.8: hidden and forced off (see AutoSpaces.removeAvailable). Checked first so nothing below can run.
        guard autoRemoveSpacesEffective else { logRestore("auto-remove spaces: skipped — feature hidden/off (stored=\(autoRemoveSpacesStored))"); return false }
        logRestore("auto-remove spaces: check before{ext=\(before.external) builtIn=\(before.builtIn)} after{ext=\(after.external) builtIn=\(after.builtIn)} enabled=\(autoRemoveSpacesEffective)")
        guard trusted else { logRestore("auto-remove spaces: skipped — no Accessibility permission"); return false }
        guard let token=builtInDisplayToken else { logRestore("auto-remove spaces: skipped — no built-in display"); return false }
        guard let all=try? spaces.spaces(displays:MacEnvironment.displays()) else { logRestore("auto-remove spaces: skipped — Spaces unreadable"); return false }
        guard let occupied=SpaceOccupancy.occupied(spaces:spaces) else { logRestore("auto-remove spaces: skipped — window occupancy unreadable"); return false }
        let active=Set(all.filter(\.active).map(\.id))
        let planned=AutoSpaces.planRemove(enabled:autoRemoveSpacesEffective,before:before,after:after,occupied:occupied,active:active,spaces:all)
        guard case .success(let ids)=planned else {
            if case .failure(let e)=planned { logRestore("auto-remove spaces: skipped — \(e.blocker) (occupied∩builtIn=\(after.builtIn.filter{ occupied.contains($0) }) active=\(active.sorted()))") }
            return false
        }
        let moved=SpaceCensus.migratedToBuiltIn(before:before,after:after)
        logRestore("auto-remove spaces: start count=\(ids.count) migrated=\(moved)")
        autoSpaces.remove(ids:ids,token:token) { [weak self] result in
            guard let self else { return }
            // Log only: the feature is hidden (AutoSpaces.removeAvailable) and the unplug notice was removed in 0.6.8.
            switch result {
            case .success(let n): self.logRestore("auto-remove spaces: removed \(n) of \(moved) migrated")
            case .failure(let e):
                NSLog("LayoutKeeper auto remove Spaces stopped: %@",e.description)
                self.logRestore("auto-remove spaces: failed (\(e.description.prefix(80)))")
            }
        }
        return true
    }
    func inspectMissionControl() {
        missionControlReport=lk("正在读取…")
        autoSpaces.inspect { [weak self] in self?.missionControlReport=$0 }
    }
    func runAutoSpacesTrial() {
        guard let token=externalDisplayToken ?? builtInDisplayToken else { autoSpacesTrialMessage=lk("找不到屏幕"); return }
        if let all=try? spaces.spaces(displays:MacEnvironment.displays()),AutoSpaces.fullScreenActive(all) { autoSpacesTrialMessage=AutoSpaces.Blocker.fullScreenActive.description; return }
        let alert=NSAlert()
        alert.messageText=lk("试一下自动加、删桌面？")
        alert.informativeText=lk("会打开调度中心，在%@上按「+」加一个桌面，确认加上后再把这个新桌面删掉。其它桌面和窗口都不会动。", "\(externalDisplayToken != nil ? lk("外接屏") : lk("内置屏"))")
        alert.addButton(withTitle:lk("开始")); alert.addButton(withTitle:lk("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        autoSpacesTrialMessage=lk("正在测试…")
        autoSpaces.trial(token:token) { [weak self] in self?.autoSpacesTrialMessage=$0 }
    }
}

/// Shared mode only. Every few seconds records the ordinary Spaces per display (read only, no AX) so that
/// (1) an unplug can be compared with the state just before it, and (2) Spaces added after a "too few Spaces"
/// notice trigger another restore. Never creates, deletes or reorders Spaces.
final class SharedSpaceWatcher {
    private weak var model: Model?
    private var timer: Timer?
    private(set) var last: SpaceCensus?
    private var lastPhysicalCount = -1
    static let interval: TimeInterval=4
    func start(model: Model) {
        self.model=model
        let t=Timer(timeInterval:Self.interval,repeats:true) { [weak self] _ in self?.tick() }
        timer=t; RunLoop.main.add(t,forMode:.common)
        tick()
    }
    private func census() -> SpaceCensus? {
        guard let model else { return nil }
        let displays=MacEnvironment.displays()
        guard let spaces=try? model.spaces.spaces(displays:displays) else { return nil }
        return SpaceCensus.take(displays,spaces,externalCount:displays.filter{ $0.role == .external }.count)
    }
    func screensChanged() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.tick() }
    }
    private func tick() {
        guard let model,model.layoutMode == .sharedExternal,!RenderMode.snapshot else { last=nil; lastPhysicalCount = -1; return }
        let physical=MonitorRecognition.physicalExternalMonitors().count
        if physical != lastPhysicalCount {
            if physical>1 && lastPhysicalCount>=0 { model.postSharedNotice(SharedNotice(kind:.multipleMonitors)) }
            else if case .multipleMonitors? = model.sharedNotice?.kind { model.sharedNotice=nil }
            lastPhysicalCount=physical
        }
        guard let now=census() else { model.logRestore("space-watch: census unreadable"); return }
        let previous=last
        last=now
        guard let previous else { return }
        if previous != now { model.logRestore("space-watch: census changed ext \(previous.externalCount)→\(now.externalCount) external \(previous.external)→\(now.external) builtIn \(previous.builtIn)→\(now.builtIn)") }
        if previous.externalCount>0 && now.externalCount==0 {
            model.pendingSpacesNeeded=nil
            // macOS moves the Spaces over a moment after the screen goes away; compare once things settle.
            DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
                guard let self,let model=self.model,model.layoutMode == .sharedExternal,let after=self.census(),after.externalCount==0 else { self?.model?.logRestore("space-watch: unplug follow-up exit — mode changed, census unreadable or external is back"); return }
                self.last=after
                let moved=SpaceCensus.migratedToBuiltIn(before:previous,after:after)
                // 0.6.8: no notice. Telling the user these desktops are safe to delete was wrong: deleting one renumbers
                // the desktops the saved layout refers to. Removal itself is forced off (see tryAutoRemoveSpaces).
                model.logRestore("space-watch: unplug settled, migratedToBuiltIn=\(moved) notice=suppressed")
                if moved>0 { _=model.tryAutoRemoveSpaces(before:previous,after:after) }
            }
            return
        }
        if now.externalCount==1,previous.externalCount==1,now.external.count>previous.external.count,
           let needed=model.pendingSpacesNeeded,model.sharedModeActive,!model.busy,!model.showingQuickRestore,!model.autoSpaces.running {
            if let until=model.pausedUntil,Date()<until { model.logRestore("space-watch: Spaces added but paused, no restore"); return }
            model.logRestore("space-watch: Spaces added (\(previous.external.count)→\(now.external.count), needed \(needed)), automatic restore again")
            _=needed   // the user added Spaces after our notice: restore again (only unambiguous windows, undoable)
            let outcome=model.directRestore(.automatic)
            if let notice=model.restoreNotice(outcome,trigger:.automatic) { model.notify?(notice) }
        }
    }
}

struct AutoSpacesFailure: Error { var description: String }
