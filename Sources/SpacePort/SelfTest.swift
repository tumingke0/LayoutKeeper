// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

/// Journal persistence for self-test restores; kept in the SelfTest folder, never next to user layouts.
final class SelfTestJournalSink {
    let directory: URL
    var url: URL?
    init(directory: URL) { self.directory=directory }
    func persist(_ journal: RestoreJournal) throws {
        if let url { try RestoreJournalStore.update(journal,at:url) } else { url=try RestoreJournalStore.create(journal,in:directory) }
    }
}

struct SelfTestOriginal { var window: ObservedWindow; var space: UInt64; var frame: Rect; var display: String }

/// One-click self-test on the user's real windows. Every write goes through the production paths:
/// AXWindows.scan / ExternalLayoutCapture.assess / MonitorRestorePlanner / ManualRestorer (execute, undo)
/// / makeControlledMover + SpaceMovePermit / AXWindows.setFrame. Nothing moves before the user confirms.
final class SelfTestRun {
    unowned let model: Model
    var report=SelfTestReport()
    var cancelRequested=false
    let timeBox: TimeInterval=60
    private let origin=ProcessInfo.processInfo.systemUptime
    private var deadline: TimeInterval = .infinity
    private var record: MonitorLayoutRecord?
    private var monitor: MonitorIdentity?
    private var displayToken=""
    private var captureSnapshot: Snapshot?
    private var captureBindings=[String:UInt64]()
    private var selection=SelfTestPlanner.Selection()
    private var touched=[String:SelfTestOriginal]()
    private var pending=[(String,()->Void)]()
    private var crossJournal: (RestoreJournal,[SpaceMovePermit],SelfTestJournalSink)?
    private var crossOK=false
    private var crossAgainOK=false
    private var foregroundOutcome: FrameWriteOutcome?
    let directory: URL
    var panel: NSPanel?

    static var reportDirectory: URL {
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        return AppInstallation.dataDirectory(applicationSupport:support).appendingPathComponent("SelfTest",isDirectory:true)
    }
    init(model: Model) { self.model=model; directory=Self.reportDirectory }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var elapsedMs: Int { Int((now-origin)*1000) }
    private func pause() { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12)) }
    private func read(_ token: String) -> ObservedWindow? { try? model.windows.readWindow(token:token) }
    private func poll(_ token: String,frame: Rect?,space: UInt64?) -> ObservedWindow? {
        var last: ObservedWindow?
        for attempt in 0..<10 {
            if attempt>0 { pause() }
            last=read(token)
            if let w=last, frame.map({w.frame.near($0)}) ?? true, space.map({w.spaceIDs==[$0]}) ?? true { return w }
        }
        return last
    }
    private func slot(_ space: UInt64?) -> Int? {
        guard let space,let snapshot=captureSnapshot else { return nil }
        return snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}.firstIndex{$0.id==space}.map{$0+1}
    }
    private func ref(_ w: ObservedWindow) -> SelfTestWindowRef { SelfTestWindowRef(window:w,slot:slot(w.spaceIDs.first)) }
    private func visibleFrame() -> Rect? { captureSnapshot?.displays.first{$0.token==displayToken}?.visible }
    private func label(of w: ObservedWindow) -> String? { record?.profile.windows.first{$0.selector.matches(w.selector)}?.desktopLabel }
    private func remember(_ w: ObservedWindow) {
        if touched[w.token]==nil, w.spaceIDs.count==1 { touched[w.token]=SelfTestOriginal(window:w,space:w.spaceIDs[0],frame:w.frame,display:displayToken) }
    }
    private func step(_ name: String,_ body: (inout SelfTestStep) throws -> Void) {
        var s=SelfTestStep(name:name); s.startedAtMs=elapsedMs; let started=now
        model.selfTestProgress=lk("正在执行：%@", "\(name)")
        do { try body(&s) } catch { s.status = .fail; s.messages.append(lk("错误：%@", "\(error)")) }
        s.durationMs=Int((now-started)*1000); report.steps.append(s)
    }

    // MARK: start: read-only capture, then one confirmation
    func start(trigger: String) {
        refreshEnvironment()
        report.capture.summary=lk("触发方式：%@", "\(trigger)")
        showPanel()
        model.selfTestProgress=lk("正在只读采集外接屏窗口（与保存相同的流程，可能需要几秒）…")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [self] in captureThenConfirm() }
    }
    private func refreshEnvironment() {
        let info=NSDictionary(contentsOfFile:"/System/Library/CoreServices/SystemVersion.plist")
        report.macOSVersion=info?["ProductVersion"] as? String ?? ""; report.macOSBuild=info?["ProductBuildVersion"] as? String ?? ""
        report.appVersion=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev"
        report.appBuild=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "dev"
        model.refreshAuthorization(); report.accessibilityTrusted=model.trusted
        report.controlledBuildSupported=model.crossSpaceEnabled; report.crossSpaceStatus=model.crossSpaceSupport.summary
    }
    private func captureThenConfirm() {
        step(lk("A 采集（与保存同一流程，只在内存中，不覆盖已保存布局）")) { s in
            guard model.trusted else { s.status = .skip; s.detail=lk("辅助功能权限未生效：%@", "\(model.accessState.guidance)"); return }
            guard let connected=model.currentExternalMonitor else { s.status = .skip; s.detail=lk("需要恰好一台已识别的外接屏"); return }
            monitor=connected.identity; displayToken=connected.runtimeDisplayToken
            report.externalDisplayToken=displayToken; report.externalMonitorName=connected.identity.name
            let started=now
            let snapshot=try model.externalLayoutSnapshot()
            let current=MonitorRecognition.externalMonitors()
            guard current.count==1,current[0].identity.key==connected.identity.key,current[0].runtimeDisplayToken==displayToken else { throw LayoutError.readbackUnavailable }
            let assessed=try ExternalLayoutCapture.assess(monitor:connected.identity,displayToken:displayToken,snapshot:snapshot,report:model.windows.latestCaptureReport)
            model.windows.applyCaptureDecisions(assessed.decisions); model.captureTrace=model.windows.captureTrace
            report.capture.scanMs=Int((now-started)*1000)
            record=assessed.record; captureSnapshot=snapshot
            fillCapture(assessed.record,snapshot:snapshot)
            captureBindings=SelfTestPlanner.groupSpaces(record:assessed.record,snapshot:snapshot,displayToken:displayToken)
            s.messages.append(lk("自动对应窗口组 %@/%@ 个", "\(captureBindings.count)", "\(Set(assessed.record.profile.windows.map(\.desktopLabel)).count)"))
            s.status = assessed.record.profile.windows.isEmpty ? .fail : .pass
            s.detail=lk("可保存 %@ 个窗口", "\(assessed.record.profile.windows.count)")
        }
        guard let record, report.steps.last?.status == .pass else { finish(); return }
        let reason=lk("跨桌面能力不可用：%@", "\(model.crossSpaceSupport.detail)")
        selection=SelfTestPlanner.select(record:record,snapshot:captureSnapshot!,displayToken:displayToken,crossSpaceAvailable:report.controlledBuildSupported,crossSpaceUnavailableReason:reason)
        guard selection.sameSpace != nil || selection.crossSpace != nil else {
            report.steps.append(skipped(lk("B 同桌面恢复"),selection.sameSpaceSkip)); report.steps.append(skipped(lk("C 跨桌面恢复"),selection.crossSpaceSkip)); finish(); return
        }
        guard confirm() else {
            report.steps.append(skipped(lk("B–D 写入步骤"),lk("用户在确认框中取消，没有移动任何窗口"))); finish(); return
        }
        report.confirmed=true; deadline=now+timeBox
        model.restoring=true; model.windows.writesApproved=true
        pending=[(lk("B 同桌面恢复"),sameSpaceStep),(lk("C1 跨桌面：用恢复功能移到另一桌面"),crossMoveStep),(lk("C2 跨桌面：撤销（回到原桌面）"),crossUndoStep),
                 (lk("C3 跨桌面：再次移出并测试后台桌面写位置/大小"),crossProbeStep),(lk("C4 跨桌面：用恢复功能回到原桌面原位置"),crossReturnStep)]
        DispatchQueue.main.async { [self] in advance() }
    }
    private func skipped(_ name: String,_ why: String?) -> SelfTestStep { var s=SelfTestStep(name:name); s.status = .skip; s.detail=why ?? ""; return s }
    private func confirm() -> Bool {
        func short(_ t: String) -> String { t.count>24 ? String(t.prefix(24))+"…" : (t.isEmpty ? lk("（无标题）") : t) }
        var lines=[lk("自检会临时移动下列真实窗口，结束时全部复位到原桌面和原位置：")]
        if let w=selection.sameSpace { lines.append(lk("• 同桌面：%@ —「%@」（外屏桌面 %@，当前桌面）：位置/大小微调约 40 像素，再用恢复功能复原。", "\(w.selector.bundleID)", "\(short(w.selector.title))", "\(slot(w.spaceIDs.first) ?? 0)")) }
        else { lines.append(lk("• 同桌面：跳过（%@）", "\(selection.sameSpaceSkip ?? "")")) }
        if let c=selection.crossSpace {
            lines.append(lk("• 跨桌面：%@ —「%@」：外屏桌面 %@ → 桌面 %@ → 撤销回桌面 %@ → 再移到桌面 %@ 并微调位置 → 用恢复功能回到桌面 %@ 原位置。", "\(c.window.selector.bundleID)", "\(short(c.window.selector.title))", "\(slot(c.source) ?? 0)", "\(slot(c.target) ?? 0)", "\(slot(c.source) ?? 0)", "\(slot(c.target) ?? 0)", "\(slot(c.source) ?? 0)"))
        } else { lines.append(lk("• 跨桌面：跳过（%@）", "\(selection.crossSpaceSkip ?? "")")) }
        lines.append(lk("\n不会切换当前桌面、启动或退出应用、改动内置屏窗口或已保存布局。约 %@ 秒内结束；可随时点浮动面板上的“停止并复位”。报告不含窗口标题，只含应用 ID 和标题短哈希。", "\(Int(timeBox))"))
        let alert=NSAlert(); alert.messageText=lk("开始一键自检？（会临时移动真实窗口）"); alert.informativeText=lines.joined(separator:"\n")
        alert.addButton(withTitle:lk("开始自检（移动以上窗口）")); alert.addButton(withTitle:lk("取消"))
        NSApp.activate(ignoringOtherApps:true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func advance() {
        if !pending.isEmpty && (cancelRequested || now>deadline) {
            let why=cancelRequested ? lk("用户点了停止") : lk("超过 %@ 秒时限", "\(Int(timeBox))")
            report.cancelled=cancelRequested; report.timedOut = !cancelRequested
            for (name,_) in pending { var s=SelfTestStep(name:name); s.detail=lk("未执行：%@", "\(why)"); report.steps.append(s) }
            pending=[]
        }
        if pending.isEmpty { finalRollback(); finish(); return }
        let (name,body)=pending.removeFirst()
        _=name; body()
        DispatchQueue.main.async { [self] in advance() }
    }

    // MARK: steps
    private func sameSpaceStep() {
        step(lk("B 同桌面恢复")) { s in
            guard let w0=selection.sameSpace else { s.status = .skip; s.detail=selection.sameSpaceSkip ?? ""; return }
            s.windows=[ref(w0)]
            guard let cur=read(w0.token),cur.selector==w0.selector,cur.spaceIDs==w0.spaceIDs,cur.frame.near(w0.frame),let visible=visibleFrame(),let label=label(of:cur) else { s.status = .skip; s.detail=lk("确认期间窗口已改变或无法回读，未写入"); return }
            remember(cur)
            let target=SelfTestPlanner.nudged(cur.frame,within:visible)
            do { try model.windows.setFrame(window:cur,to:target) } catch { s.messages.append(lk("微调写入（AX）失败：%@", "\(error)")) }
            let nudged=poll(cur.token,frame:target,space:nil)
            s.readbacks.append(SelfTestReadback(label:lk("微调后"),observed:nudged,expectedFrame:target,expectedSpace:cur.spaceIDs[0]))
            if let nudged { foregroundOutcome=FrameWriteOutcome(observed:nudged.frame,target:target); s.messages.append(lk("当前桌面微调：位置生效 %@，尺寸生效 %@", "\(foregroundOutcome!.positionApplied)", "\(foregroundOutcome!.sizeApplied)")) }
            if let nudged,nudged.frame.near(cur.frame) { s.status = .skip; s.detail=lk("应用没有接受 AX 微调，无法测试恢复"); return }
            var bindings=captureBindings
            if bindings[label]==nil { bindings[label]=cur.spaceIDs[0]; s.messages.append(lk("该窗口组未能自动对应，改用窗口当前桌面")) }
            let outcome=try restore(token:cur.token,groupSpaces:bindings,crossSpace:false,into:&s)
            let final=poll(cur.token,frame:cur.frame,space:cur.spaceIDs[0])
            let rb=SelfTestReadback(label:lk("恢复后"),observed:final,expectedFrame:cur.frame,expectedSpace:cur.spaceIDs[0]); s.readbacks.append(rb)
            s.status = outcome?.0 == .verified && rb.matches ? .pass : .fail
        }
    }
    private func crossTargetsReady(_ s: inout SelfTestStep) -> (SelfTestPlanner.CrossSpaceChoice,ObservedWindow,String)? {
        guard let c=selection.crossSpace else { s.status = .skip; s.detail=selection.crossSpaceSkip ?? ""; return nil }
        s.windows=[ref(c.window)]
        guard let cur=read(c.window.token),cur.selector==c.window.selector,let label=label(of:cur) else { s.status = .skip; s.detail=lk("窗口无法回读或标识已改变（例如标题变化）"); return nil }
        return (c,cur,label)
    }
    private func crossMoveStep() {
        step(lk("C1 跨桌面：用恢复功能移到另一桌面")) { s in
            guard let (c,cur,label)=crossTargetsReady(&s) else { return }
            guard cur.spaceIDs==[c.source],cur.frame.near(c.window.frame) else { s.status = .skip; s.detail=lk("确认期间窗口桌面或位置已改变，未写入"); return }
            remember(cur)
            let outcome=try restore(token:cur.token,groupSpaces:[label:c.target],crossSpace:true,into:&s)
            let moved=poll(cur.token,frame:nil,space:c.target)
            let rb=SelfTestReadback(label:lk("移动后"),observed:moved,expectedFrame:cur.frame,expectedSpace:c.target); s.readbacks.append(rb)
            if let (_,report,permits,sink)=outcome, let journal=report.journal { crossJournal=(journal,permits,sink) }
            crossOK = outcome?.0 == .verified && rb.matches
            s.status = crossOK ? .pass : .fail
            if !crossOK { s.detail=lk("跨桌面移动未通过；执行器已按设计尝试回滚，后续跨桌面步骤跳过") }
        }
    }
    private func crossUndoStep() {
        step(lk("C2 跨桌面：撤销（回到原桌面）")) { s in
            guard crossOK,let (journal,permits,sink)=crossJournal,let c=selection.crossSpace,let orig=touched[c.window.token] else { s.status = .skip; s.detail=lk("C1 未通过"); return }
            s.windows=[ref(c.window)]
            guard journal.canUndo else { s.status = .fail; s.detail=lk("日志显示不可撤销"); return }
            let result=ManualRestorer.undo(journal,windows:model.windows,spaces:model.makeControlledMover(permits),approved:true,polls:8,pause:{ self.pause() },persist:sink.persist)
            for r in result.results { s.messages.append(lk("撤销：%@ · %@", "\(r.outcome.rawValue)", "\(r.detail)")) }
            s.messages+=result.persistenceIssues.map{lk("日志：%@", "\($0)")}
            let back=poll(c.window.token,frame:orig.frame,space:orig.space)
            let rb=SelfTestReadback(label:lk("撤销后"),observed:back,expectedFrame:orig.frame,expectedSpace:orig.space); s.readbacks.append(rb)
            s.status = result.results.contains{$0.outcome == .verified} && rb.matches ? .pass : .fail
        }
    }
    private func crossProbeStep() {
        step(lk("C3 跨桌面：再次移出并测试后台桌面写位置/大小")) { s in
            guard crossOK,report.steps.last?.status == .pass else { s.status = .skip; s.detail=lk("C1/C2 未通过"); return }
            guard let (c,cur,label)=crossTargetsReady(&s),let visible=visibleFrame() else { return }
            let outcome=try restore(token:cur.token,groupSpaces:[label:c.target],crossSpace:true,into:&s)
            guard let moved=poll(cur.token,frame:nil,space:c.target),moved.spaceIDs==[c.target],outcome?.0 == .verified else { s.status = .fail; s.detail=lk("第二次移出未通过"); return }
            crossAgainOK=true
            s.readbacks.append(SelfTestReadback(label:lk("再次移出后"),observed:moved,expectedFrame:nil,expectedSpace:c.target))
            let targetActive=captureSnapshot?.spaces.first{$0.id==c.target}?.active ?? false
            if targetActive { s.status = .pass; s.detail=lk("目标是当前桌面，后台写几何未测试"); return }
            let probe=SelfTestPlanner.nudged(moved.frame,within:visible)
            do { try model.windows.setFrame(window:moved,to:probe) } catch { s.messages.append(lk("后台桌面 AX 写入报错：%@", "\(error)")) }
            let after=poll(cur.token,frame:probe,space:c.target)
            let rb=SelfTestReadback(label:lk("后台桌面写位置/大小"),observed:after,expectedFrame:probe,expectedSpace:c.target); s.readbacks.append(rb)
            let background=after.map{FrameWriteOutcome(observed:$0.frame,target:probe)}
            if let background { s.messages.append(lk("后台桌面微调：位置生效 %@，尺寸生效 %@", "\(background.positionApplied)", "\(background.sizeApplied)")) }
            if let foregroundOutcome { s.messages.append(lk("对照当前桌面（步骤 B）：位置生效 %@，尺寸生效 %@", "\(foregroundOutcome.positionApplied)", "\(foregroundOutcome.sizeApplied)")) }
            // Pass when the background write behaves like the same write on the active Space (or fully applies).
            let same=background != nil && (background!.complete || background==foregroundOutcome)
            s.status = same && after?.spaceIDs==[c.target] ? .pass : .fail
            s.detail = background?.complete == true ? lk("窗口在非当前桌面时，AX 位置/大小写入有效") :
                (same ? lk("后台桌面写入结果与当前桌面相同（应用自身限制，不是后台桌面问题）") : lk("后台桌面写入结果与当前桌面不同"))
        }
    }
    private func crossReturnStep() {
        step(lk("C4 跨桌面：用恢复功能回到原桌面原位置")) { s in
            guard crossAgainOK,let c=selection.crossSpace,let orig=touched[c.window.token] else { s.status = .skip; s.detail=lk("C3 未完成移出"); return }
            guard let (_,cur,label)=crossTargetsReady(&s) else { return }
            let outcome=try restore(token:cur.token,groupSpaces:[label:captureBindings[label] ?? orig.space],crossSpace:true,into:&s)
            let back=poll(cur.token,frame:orig.frame,space:orig.space)
            let rb=SelfTestReadback(label:lk("回到原桌面后"),observed:back,expectedFrame:orig.frame,expectedSpace:orig.space); s.readbacks.append(rb)
            s.status = outcome?.0 == .verified && rb.matches ? .pass : .fail
        }
    }
    /// Production planning + execution for one window; returns the executor outcome for that entry.
    private func restore(token: String,groupSpaces: [String:UInt64],crossSpace: Bool,into s: inout SelfTestStep) throws -> (Outcome,ManualRestoreReport,[SpaceMovePermit],SelfTestJournalSink)? {
        guard let record,let monitor else { throw LayoutError.readbackUnavailable }
        let snapshot=try model.windows.snapshot()
        let full=try MonitorRestorePlanner.plan(record:record,monitor:monitor,displayToken:displayToken,snapshot:snapshot,groupSpaces:groupSpaces,allowCrossSpace:crossSpace && model.crossSpaceEnabled)
        let plan=SelfTestPlanner.restrict(full,toToken:token)
        guard let index=plan.entries.firstIndex(where:{$0.window?.token==token}) else { s.messages.append(lk("规划：找不到该窗口")); return nil }
        let entry=plan.entries[index]
        s.messages.append(lk("规划：%@ · %@", "\(entry.status.rawValue)", "\(entry.reason)"))
        guard entry.status == .ready else { return nil }
        let permits=crossSpace ? try model.crossSpacePermits([entry],snapshot:snapshot) : []
        let sink=SelfTestJournalSink(directory:directory.appendingPathComponent("transactions",isDirectory:true))
        let result=ManualRestorer.execute(plan,windows:model.windows,spaces:permits.isEmpty ? nil : model.makeControlledMover(permits),approved:true,polls:8,pause:{ self.pause() },persist:sink.persist)
        let r=result.results[index]
        s.messages.append(lk("执行：%@ · %@", "\(r.outcome.rawValue)", "\(r.detail)"))
        s.messages+=result.persistenceIssues.map{lk("日志：%@", "\($0)")}
        return (r.outcome,result,permits,sink)
    }

    // MARK: always-run rollback
    private func finalRollback() {
        step(lk("D 最终复位（每个动过的窗口回到初始桌面与位置）")) { s in
            guard !touched.isEmpty else { s.status = .skip; s.detail=lk("没有窗口被写入"); return }
            var allOK=true
            for (token,orig) in touched.sorted(by:{$0.key<$1.key}) {
                s.windows.append(ref(orig.window))
                if let n=read(token),n.spaceIDs==[orig.space],n.frame.near(orig.frame) {
                    s.readbacks.append(SelfTestReadback(label:lk("%@ 已在原位", "\(token)"),observed:n,expectedFrame:orig.frame,expectedSpace:orig.space)); continue
                }
                s.messages+=returnWindow(token:token,orig:orig)
                let rb=SelfTestReadback(label:lk("%@ 复位后", "\(token)"),observed:poll(token,frame:orig.frame,space:orig.space),expectedFrame:orig.frame,expectedSpace:orig.space)
                s.readbacks.append(rb); if !rb.matches { allOK=false }
            }
            s.status = allOK ? .pass : .fail
            if !allOK { s.detail=lk("有窗口未能完全复位，请按读回值手动检查") }
        }
    }
    private func returnWindow(token: String,orig: SelfTestOriginal) -> [String] {
        var messages=[String]()
        func attempt(frame: Rect) -> Bool {
            guard let snapshot=try? model.windows.snapshot(),let current=snapshot.windows.first(where:{$0.token==token}),
                  let display=snapshot.displays.first(where:{$0.token==orig.display}) else { messages.append(lk("复位：窗口或屏幕无法回读")); return false }
            let saved=SavedWindow(selector:current.selector,displayRole:.external,desktopLabel:lk("自检复位"),normalizedFrame:frame.normalized(in:display.visible))
            let entry=PlanEntry(saved:saved,status:.ready,reason:lk("自检复位"),window:current,targetSpace:orig.space,targetDisplay:orig.display,targetFrame:frame)
            let plan=RestorePlan(session:snapshot.session,topology:snapshot.topology,entries:[entry])
            let permits=current.spaceIDs==[orig.space] ? [] : ((try? model.crossSpacePermits([entry],snapshot:snapshot)) ?? [])
            if current.spaceIDs != [orig.space] && permits.isEmpty { messages.append(lk("复位：跨桌面许可无法建立")); return false }
            let sink=SelfTestJournalSink(directory:directory.appendingPathComponent("transactions",isDirectory:true))
            let result=ManualRestorer.execute(plan,windows:model.windows,spaces:permits.isEmpty ? nil : model.makeControlledMover(permits),approved:true,polls:8,pause:{ self.pause() },persist:sink.persist)
            messages.append(lk("复位执行：%@ · %@", "\(result.results[0].outcome.rawValue)", "\(result.results[0].detail)"))
            return result.results[0].outcome == .verified
        }
        if attempt(frame:orig.frame) { return messages }
        // Fallbacks: first get the window back onto its Space without geometry, then fix geometry on that Space.
        if let n=read(token),n.spaceIDs != [orig.space] { _=attempt(frame:n.frame) }
        if let n=read(token),n.spaceIDs==[orig.space],!n.frame.near(orig.frame) {
            do { try model.windows.setFrame(window:n,to:orig.frame); messages.append(lk("复位：已直接写回原位置/大小")) } catch { messages.append(lk("复位：直接写回失败：%@", "\(error)")) }
        }
        return messages
    }

    // MARK: report
    private func fillCapture(_ record: MonitorLayoutRecord,snapshot: Snapshot) {
        let measured=record.captureReport ?? model.windows.latestCaptureReport
        report.capture.savedWindowCount=record.profile.windows.count
        report.capture.completeness=measured.completeness.rawValue
        report.capture.summary+=lk("；")+measured.summary
        report.capture.globalReasons=measured.globalReasons
        let ordinary=snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}
        report.capture.slots=measured.spaces.map { space in
            SelfTestSlot(slot:space.index,spaceID:space.index<=ordinary.count ? ordinary[space.index-1].id : 0,active:space.active,cgCandidates:space.cgCandidates,captured:space.captured)
        }
        let trace=model.windows.captureTrace
        report.capture.trace=trace
        var apps=[SelfTestAppCounts]()
        for app in measured.applications where app.count(.applicationsVisited)>0 && (app.count(.cgCandidates)>0 || app.count(.captured)>0) {
            var sources=[String:Int]()
            for entry in trace where entry.bundleID==app.bundleID { if let source=entry.axSource { sources[source.rawValue,default:0]+=1 } }
            let unresolved:Int=(app.reasons[CaptureReason.remoteTokenUnresolved.rawValue] ?? 0)+(app.reasons[CaptureReason.remoteTokenSkipped.rawValue] ?? 0)
            apps.append(SelfTestAppCounts(bundleID:app.bundleID,captured:app.count(.captured),cgCandidates:app.count(.cgCandidates),notInAX:app.count(.cgNotInAX),sources:sources,
                                          remoteWanted:app.count(.remoteTokenWanted),remoteResolved:app.count(.remoteTokenResolved),unresolved:unresolved))
        }
        report.capture.applications=apps.sorted{$0.bundleID<$1.bundleID}
    }
    private func finish() {
        model.windows.writesApproved=false; model.restoring=false
        report.finishedAt=Date()
        let formatter=DateFormatter(); formatter.dateFormat="yyyyMMdd-HHmmss"; formatter.locale=Locale(identifier:"en_US_POSIX")
        let base=directory.appendingPathComponent("selftest-\(formatter.string(from:report.startedAt))")
        let text=report.text
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try report.json().write(to:base.appendingPathExtension("json"),atomically:true,encoding:.utf8)
            try text.write(to:base.appendingPathExtension("txt"),atomically:true,encoding:.utf8)
            model.selfTestReportURL=base.appendingPathExtension("txt")
        } catch { model.selfTestReportURL=nil; model.selfTestProgress=lk("报告写入失败：%@", "\(error)") }
        model.selfTestReportText=text
        let counts=Dictionary(grouping:report.steps,by:\.status).mapValues(\.count)
        model.selfTestSummary=lk("自检结束：总体 %@；通过 %@，失败 %@，跳过 %@，未执行 %@。", "\(report.overall.rawValue)", "\(counts[.pass] ?? 0)", "\(counts[.fail] ?? 0)", "\(counts[.skip] ?? 0)", "\(counts[.notRun] ?? 0)")+(model.selfTestReportURL.map{lk("报告：%@", "\($0.path)")} ?? "")
        model.selfTestProgress=model.selfTestSummary
        model.selfTestRunning=false
        panel?.close(); panel=nil
        model.selfTestRun=nil
    }
    private func showPanel() {
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:440,height:150),styleMask:[.titled,.utilityWindow,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.title=lk("LayoutKeeper 一键自检"); panel.level = .floating; panel.isReleasedWhenClosed=false; panel.hidesOnDeactivate=false
        panel.contentView=NSHostingView(rootView:SelfTestPanelView(model:model))
        if let screen=NSScreen.main { panel.setFrameOrigin(NSPoint(x:screen.visibleFrame.maxX-460,y:screen.visibleFrame.maxY-180)) }
        panel.orderFrontRegardless(); self.panel=panel
    }
}

struct SelfTestPanelView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(model.selfTestProgress).font(.callout).fixedSize(horizontal:false,vertical:true)
            HStack { Spacer(); Button(lk("停止并复位")) { model.selfTestRun?.cancelRequested=true; model.selfTestProgress=lk("已请求停止，当前步骤结束后复位…") }.disabled(model.selfTestRun==nil) }
        }.padding(14).frame(width:440)
    }
}

extension Model {
    func beginSelfTest(trigger: String) {
        guard !selfTestRunning,!restoring else { return }
        selfTestRunning=true; selfTestSummary=""; selfTestReportText=""; selfTestReportURL=nil
        let run=SelfTestRun(model:self); selfTestRun=run
        run.start(trigger:trigger)
    }
    func copySelfTestReport() {
        guard !selfTestReportText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selfTestReportText,forType:.string)
    }
    func revealSelfTestReport() {
        if let url=selfTestReportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(SelfTestRun.reportDirectory) }
    }
}

struct SelfTestSection: View {
    @ObservedObject var model: Model
    var body: some View {
        GroupBox(lk("一键自检（会临时移动真实窗口）")) {
            VStack(alignment:.leading,spacing:8) {
                Text(lk("用你当前的真实窗口走一遍：采集 → 同桌面恢复 → 跨桌面移动/撤销/恢复 → 全部复位。开始前会弹出确认框列出要动的窗口；不确认不会移动任何窗口。不会写入已保存的布局。"))
                    .font(.callout)
                HStack {
                    Button(lk("开始一键自检…")) { model.beginSelfTest(trigger:"button") }.disabled(model.selfTestRunning || model.restoring || !model.trusted)
                    Button(lk("复制报告")) { model.copySelfTestReport() }.disabled(model.selfTestReportText.isEmpty)
                    Button(lk("在 Finder 中显示")) { model.revealSelfTestReport() }
                }
                if !model.selfTestSummary.isEmpty { Text(model.selfTestSummary).font(.caption).textSelection(.enabled) }
                if !model.selfTestReportText.isEmpty {
                    DisclosureGroup(lk("查看报告")) { ScrollView { Text(model.selfTestReportText).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:240) }
                }
            }.padding(8)
        }
    }
}
