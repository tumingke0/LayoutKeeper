// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

extension Model {
    var systemBuildText: String {
        let version=NSDictionary(contentsOfFile:"/System/Library/CoreServices/SystemVersion.plist")
        return "\(version?["ProductVersion"] as? String ?? "?") \(version?["ProductBuildVersion"] as? String ?? "?")"
    }
    var crossSpaceStatusText: String { crossSpaceSupport.summary+lk("。")+crossSpaceSupport.detail }
    func appName(_ bundleID: String) -> String {
        if let cached=appNameCache[bundleID] { return cached }
        var name=bundleID
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) {
            name=FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:"")
        }
        appNameCache[bundleID]=name; return name
    }
    /// Reads the saved layout for the current external monitor and builds the one-click preview. Never moves windows.
    @discardableResult func prepareQuickRestore() -> Bool {
        guard !restoring,!selfTestRunning else { logRestore("prepare: exit — busy (restoring=\(restoring) selfTest=\(selfTestRunning))"); return false }
        quickPlan=nil; quickResults=[:]; quickChoices=[:]; quickSnapshot=nil; quickRecord=nil; quickContext=nil
        refreshAuthorization()
        guard trusted else { quickMessage=accessState.guidance; logRestore("prepare: exit — Accessibility permission missing"); return false }
        guard let monitor=currentExternalMonitor else { logRestore("prepare: exit — no single external monitor (externals=\(externalMonitors.count))"); quickMessage=externalMonitors.isEmpty ? lk("没有检测到外接屏。") : lk("目前只支持同时连接一块外接屏。"); return false }
        do {
            let url=try monitorRecordURL(monitor.identity)
            var saved: MonitorLayoutRecord?
            if FileManager.default.fileExists(atPath:url.path) {
                let record=try MonitorLayoutStore.load(from:url)
                guard record.monitor.key==monitor.identity.key else { logRestore("prepare: exit — layout file key \(record.monitor.key) != monitor \(monitor.identity.key)"); throw LayoutError.invalidProfile }
                logRestore("prepare: layout \(url.lastPathComponent) key=\(record.monitor.key) savedAt=\(record.savedAt) windows=\(record.profile.windows.count) display=\(RestoreLog.d(monitor.runtimeDisplayToken))")
                saved=record
            }
            let arrival=activeArrival(for:monitor.identity,saved:saved)
            guard saved != nil || arrival != nil else {
                logRestore("prepare: exit — no layout file for \(monitor.identity.key) (\(url.lastPathComponent)) and no live record")
                quickMessage=lk("这块屏幕（%@）还没有保存过布局。先把窗口摆好，再点「保存布局」。", "\(monitor.identity.name)"); return false
            }
            let warm=(saved?.profile.windows ?? [])+(arrival?.record.windows ?? [])
            warmUpSavedApps(MonitorLayoutRecord(monitor:monitor.identity,profile:Profile(location:monitor.identity.name,windows:warm)))
            windows.patientReads=true; defer { windows.patientReads=false }
            let snapshot=try externalLayoutSnapshot()
            let current=MonitorRecognition.externalMonitors()
            guard current.count==1,current[0].identity.key==monitor.identity.key,current[0].runtimeDisplayToken==monitor.runtimeDisplayToken else { logRestore("prepare: exit — monitor changed during scan (now \(current.map{ "\($0.identity.key)@\(RestoreLog.d($0.runtimeDisplayToken))" }))"); throw LayoutError.readbackUnavailable }
            logRestore("prepare: scanned windows=\(snapshot.windows.count) issues=\(windows.issues.count) crossSpace=\(crossSpaceEnabled) shared=\(monitor.identity.isSharedExternal)")
            guard let effective=effectiveLayout(monitor:monitor.identity,saved:saved,snapshot:snapshot) else { throw LayoutError.invalidProfile }
            logRestore("prepare: restoring from \(arrival == nil ? "saved layout" : "live record + saved layout") windows=\(effective.record.profile.windows.count)")
            quickRecord=effective.record; quickContext=effective.context; quickSnapshot=snapshot; quickDisplayToken=monitor.runtimeDisplayToken; quickMonitor=monitor.identity
            replanQuick()
            return quickPlan != nil
        } catch { quickMessage=lk("无法生成恢复预览，没有移动任何窗口：%@", "\(error)"); logRestore("prepare: exit — error \(String(describing:error).prefix(160))"); return false }
    }
    func replanQuick() {
        guard let record=quickRecord,let snapshot=quickSnapshot,let display=quickDisplayToken,let monitor=quickMonitor else { quickPlan=nil; return }
        do {
            let plan=try QuickRestorePlanner.plan(record:record,monitor:monitor,displayToken:display,snapshot:snapshot,choices:quickChoices,allowCrossSpace:crossSpaceEnabled,crossSpaceBlockReason:lk("需要跨桌面移动，但这台 Mac 不支持：%@", "\(crossSpaceSupport.summary)"),browserProfiles:ChromeProfiles.load()?.map(snapshot.windows) ?? [:],context:quickContext)
            quickPlan=plan
            var text=""
            if plan.missingDesktops>0,monitor.isSharedExternal { text+=lk("还缺 %@ 个桌面：有 %@ 组窗口暂时没有移动（不会挤到别的桌面上）。在调度中心按「+」补 %@ 个桌面后会自动再恢复。", "\(plan.missingDesktops)", "\(plan.unplacedGroups.count)", "\(plan.missingDesktops)") }
            else if plan.missingDesktops>0 { text+=lk("还缺 %@ 个桌面：有 %@ 组窗口暂时没有移动（不会挤到别的桌面上）。请先在调度中心新建桌面，再重新预览。", "\(plan.missingDesktops)", "\(plan.unplacedGroups.count)") }
            if plan.items.contains(where:{$0.reason==QuickRestorePlanner.oldRecordReason}) { text+=lk("这份布局由旧版本保存，缺少桌面顺序，请重新保存一次。") }
            if !windows.issues.isEmpty { text+=lk("部分窗口信息读取失败，预览可能不完整。") }
            quickMessage=text
        } catch { quickPlan=nil; quickMessage=lk("屏幕或布局无法可靠对应，请重新预览。"); logRestore("replan: planner threw \(String(describing:error).prefix(160)) (display \(RestoreLog.d(display)) role/visible mismatch?)") }
    }
    func setQuickChoice(_ index: Int,_ choice: QuickChoice?) {
        if let choice { quickChoices[index]=choice } else { quickChoices.removeValue(forKey:index) }
        quickResults=[:]; replanQuick()
    }
    /// Executes the previewed ready items (the preview's confirm button is the user's approval).
    /// `autoOnly` restricts execution to items matched without user input and on verified paths.
    @discardableResult func executeQuickRestore(autoOnly: Bool = false) -> (verified: Int,attempted: Int) {
        guard !restoring,let preview=quickPlan,let record=quickRecord,let display=quickDisplayToken,let monitor=quickMonitor else { logRestore("execute: not started (busy or no plan)"); return (0,0) }
        refreshAuthorization(); guard trusted else { quickMessage=accessState.guidance; logRestore("execute: exit — Accessibility permission missing"); return (0,0) }
        let tag=autoOnly ? "auto" : "manual"
        lastRestoreFailures=[]
        windows.patientReads=true; defer { windows.patientReads=false }
        let fresh: Snapshot
        do {
            fresh=try externalLayoutSnapshot()
            let current=MonitorRecognition.externalMonitors()
            guard current.count==1,current[0].identity.key==monitor.key,current[0].runtimeDisplayToken==display else { logRestore("execute: exit — monitor changed before execution"); throw LayoutError.readbackUnavailable }
        } catch { quickMessage=lk("执行前重新读取窗口失败，没有移动任何窗口：%@", "\(error)"); logRestore("execute: re-read failed (\(String(describing:error).prefix(80)))"); return (0,0) }
        _=record
        // Identification happened once, in the preview. Here only check that each chosen window still exists.
        let exec=QuickRestorePlanner.executionPlan(preview,autoOnly:autoOnly,fresh:fresh)
        var plan=exec.plan
        let dropped=exec.gone.count
        logRestore("execute \(tag): entries=\(plan.entries.count) gone=\(exec.gone) (no re-match; existence check only)")
        guard plan.entries.contains(where:{$0.status == .ready}) else { logRestore("execute: nothing to run (gone=\(exec.gone))"); quickSnapshot=fresh; replanQuick(); quickMessage=lk("没有需要恢复的窗口。")+(dropped>0 ? lk("有 %@ 个窗口在预览之后关闭了。", "\(dropped)") : ""); return (0,0) }
        let savedIndexForEntry=exec.savedIndex
        // Global precondition: the build gate. Everything else is decided per window.
        var permits=[SpaceMovePermit]()
        var blockedCount=0
        if crossSpaceEnabled {
            let split=MoveScope.partition(plan,snapshot:fresh) { entry in try self.singlePermit(entry,snapshot:fresh) }
            plan=split.plan; permits=split.permits; blockedCount=split.blocked.count
        } else {
            for i in plan.entries.indices where plan.entries[i].status == .ready && MoveScope.needsMove(plan.entries[i]) {
                plan.entries[i].status = .blocked; plan.entries[i].reason=lk("无法跨桌面移动：这台 Mac 不支持跨桌面恢复"); blockedCount += 1
            }
        }
        let runnable=plan.entries.filter{$0.status == .ready}.count
        for e in plan.entries where e.status != .ready { logRestore("execute \(tag): pre-blocked \(e.window?.token ?? "-") \(e.saved.selector.bundleID) status=\(e.status) reason=\"\(e.reason)\"") }
        logRestore("execute \(tag): runnable=\(runnable) crossSpaceEnabled=\(crossSpaceEnabled) permits=\(permits.count) blocked=\(blockedCount) deferred=\(deferredRestoreBundles.sorted())")
        restoring=true; windows.writesApproved=true
        defer { restoring=false; windows.writesApproved=false }
        var journalURL: URL?
        let mover=permits.isEmpty ? nil : makeControlledMover(permits)
        let report=ManualRestorer.execute(plan,windows:windows,spaces:mover,approved:true,polls:8,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))},deferredBundles:deferredRestoreBundles,persist:{ journal in
            if let url=journalURL { try RestoreJournalStore.update(journal,at:url) }
            else {
                guard let directory=self.layoutDirectory else { throw LayoutError.unsupported }
                journalURL=try RestoreJournalStore.create(journal,in:directory.appendingPathComponent("transactions",isDirectory:true))
            }
        })
        if let journal=report.journal { lastRestoreJournal=journal; lastRestoreJournalURL=journalURL; lastRestorePermits=permits }
        lastRestoreFailures=report.failures
        for failure in report.failures { recentlyFailedBundles[failure.bundleID]=Date() }
        for entry in report.journal?.entries ?? [] where [.verified,.unchanged].contains(entry.state) { recentlyFailedBundles[entry.before.selector.bundleID]=nil }
        logRestoreLines(RestoreLog.journalLines(trigger:tag,report:report)+report.persistenceIssues.map{ "exec \(tag) persistence issue: \($0.prefix(160))" })
        logRestore(RestoreLog.summary(trigger:tag,report:report)+(blockedCount>0 ? " crossSpaceBlocked=\(blockedCount)" : ""))
        var results=[Int:RestoreResult]()
        for (offset,result) in report.results.enumerated() where savedIndexForEntry[offset]>=0 { results[savedIndexForEntry[offset]]=result }
        quickResults=results; externalRestoreResults=report.results
        // Re-read the already-scanned windows (no rescan) so undo keeps the same window handles.
        if let after=try? windows.snapshot() { quickSnapshot=after; quickChoices=[:]; replanQuick() }
        let verified=report.results.filter{$0.outcome == .verified}.count
        var text=lk("已恢复 %@/%@ 个窗口（桌面、位置和大小均已回读确认）。", "\(verified)", "\(runnable)")
        if blockedCount>0 { text+=lk("%@ 个窗口无法跨桌面移动，已单独跳过，原因见对应行。", "\(blockedCount)") }
        if verified<runnable { text+=lk("未通过的项目已尝试回滚，请查看逐项结果。") }
        if dropped>0 { text+=lk("有 %@ 个窗口在预览之后关闭了，本次没有处理。", "\(dropped)") }
        if report.journal?.canUndo == true { text+=lk("可以点「撤销上次恢复」。") }
        if !report.persistenceIssues.isEmpty { text+=lk("操作日志写入失败，撤销记录可能不完整。") }
        quickMessage=text
        return (verified,runnable)
    }
}

/// Three status colours only: green = will restore / restored, yellow = needs you, grey = nothing to do or skipped.
extension QuickRestoreItem {
    var badge: (text: String,icon: String,tone: Tone) {
        switch state {
        case .ready:
            if crossDisplay { return (lk("从另一块屏幕移回"),"display.2",.success) }
            if moveSpace { return (lk("移到桌面 %@", "\(targetSlot ?? 0)"),"arrow.right.square",.success) }
            return (lk("调整位置"),"arrow.up.left.and.arrow.down.right",.success)
        case .needsConfirmation: return (lk("需要确认"),"questionmark.circle",.warning)
        case .alreadyInPlace: return (lk("已在原位"),"checkmark",.neutral)
        case .blocked: return (lk("无法恢复"),"minus.circle",.neutral)
        case .missing: return (lk("未打开"),"moon.zzz",.neutral)
        case .skippedByUser: return (lk("已跳过"),"forward",.neutral)
        }
    }
}

struct QuickRestoreSheet: View {
    @ObservedObject var model: Model
    var onClose: (() -> Void)?=nil
    @Environment(\.dismiss) var dismiss
    @State var showDetails=false
    var items: [QuickRestoreItem] { model.quickPlan?.items ?? [] }
    func count(_ states: Set<QuickItemState>) -> Int { items.filter{states.contains($0.state)}.count }
    var confirmItems: [QuickRestoreItem] { items.filter{ $0.state == .needsConfirmation || (model.quickChoices[$0.savedIndex] != nil && $0.state != .skippedByUser) } }
    var restoredCount: Int { model.quickResults.values.filter{$0.outcome == .verified}.count }
    var failedCount: Int { model.quickResults.values.filter{$0.outcome != .verified}.count }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:12) {
                Image(systemName:"arrow.uturn.backward.circle.fill").font(.system(size:26)).foregroundStyle(Color.accentColor)
                VStack(alignment:.leading,spacing:2) {
                    Text(lk("恢复「%@」", "\(model.quickMonitor.map{ model.monitorPreferences.displayName($0) } ?? model.currentMonitorName ?? lk("外接屏"))")).font(.title3.weight(.semibold))
                    if let record=model.quickRecord {
                        Text(lk("第 N 个保存的桌面对应现在的第 N 个桌面 · 共 %@ 个窗口", "\(record.profile.windows.count)")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if !model.crossSpaceEnabled || model.crossSpaceSupport.isUntested {
                Label(model.crossSpaceEnabled ? lk("此系统版本尚未运行过一键自检，每个窗口仍会回读确认") : lk("这台 Mac 不支持跨桌面移动，只恢复同一桌面内的位置"),
                      systemImage:"info.circle").font(.caption).foregroundStyle(.secondary).help(model.crossSpaceSupport.detail)
            }
            if let plan=model.quickPlan,plan.missingDesktops>0 {
                Label(lk("还缺 %@ 个桌面，有 %@ 组窗口暂时没有移动。请先在调度中心新建桌面，再点「重新预览」。", "\(plan.missingDesktops)", "\(plan.unplacedGroups.count)"),systemImage:"plus.rectangle.on.rectangle")
                    .font(.callout).foregroundStyle(Tone.warning.color).padding(10).frame(maxWidth:.infinity,alignment:.leading)
                    .background(RoundedRectangle(cornerRadius:10,style:.continuous).fill(Tone.warning.color.opacity(0.10)))
            }
            summary
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if items.isEmpty {
                        Text(model.quickMessage.isEmpty ? lk("正在读取…") : model.quickMessage).foregroundStyle(.secondary).padding(30).frame(maxWidth:.infinity).card(radius:14)
                    }
                    if !confirmItems.isEmpty {
                        Text(lk("需要你确认")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        rows(confirmItems)
                    }
                    if !items.isEmpty {
                        DisclosureGroup(isExpanded:$showDetails) {
                            rows(items).padding(.top,6)
                        } label: {
                            Text(showDetails ? lk("收起详情") : lk("查看详情（%@ 个窗口）", "\(items.count)")).font(.callout)
                                .contentShape(Rectangle()).onTapGesture { withAnimation(.easeInOut(duration:0.15)) { showDetails.toggle() } }
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if !model.quickMessage.isEmpty && !items.isEmpty {
                Text(model.quickMessage).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            HStack {
                Button(lk("重新预览")) { model.prepareQuickRestore() }
                if model.lastRestoreJournal?.canUndo == true {
                    Button(lk("撤销上次恢复")) { model.quickUndo() }.buttonStyle(.link).disabled(!model.trusted || model.restoring)
                }
                Spacer()
                Button(lk("关闭")) { if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                let n=model.quickPlan?.readyCount ?? 0
                Button(n>0 ? lk("恢复 %@ 个窗口", "\(n)") : lk("没有需要恢复的窗口")) { model.executeQuickRestore() }
                    .primaryButton().keyboardShortcut(.defaultAction)
                    .disabled(n==0 || !model.trusted || model.restoring)
            }.controlSize(.large)
        }
        .padding(22).padding(.top,RenderMode.snapshot ? 0 : 8).frame(width:620,height:560)
        .windowBackdrop()
        .disabled(model.restoring)
    }
    private var summary: some View {
        HStack(spacing:6) {
            if !model.quickResults.isEmpty {
                if restoredCount>0 { Pill(text:lk("已恢复 %@", "\(restoredCount)"),systemImage:"checkmark",tone:.success) }
                if failedCount>0 { Pill(text:lk("未通过 %@", "\(failedCount)"),systemImage:"exclamationmark",tone:.warning) }
            }
            if count([.ready])>0 { Pill(text:lk("将恢复 %@", "\(count([.ready]))"),systemImage:"arrow.uturn.backward",tone:.success) }
            if count([.needsConfirmation])>0 { Pill(text:lk("需要确认 %@", "\(count([.needsConfirmation]))"),systemImage:"questionmark",tone:.warning) }
            if count([.alreadyInPlace])>0 && model.quickResults.isEmpty { Pill(text:lk("已在原位 %@", "\(count([.alreadyInPlace]))"),tone:.neutral) }
            if count([.blocked,.missing,.skippedByUser])>0 { Pill(text:lk("跳过 %@", "\(count([.blocked,.missing,.skippedByUser]))"),tone:.neutral) }
            Spacer()
        }
    }
    private func rows(_ list: [QuickRestoreItem]) -> some View {
        VStack(spacing:0) {
            ForEach(Array(list.enumerated()),id:\.element.id) { index,item in
                QuickRestoreRow(model:model,item:item)
                if index<list.count-1 { Divider().padding(.leading,54) }
            }
        }.padding(.vertical,4).card(radius:14)
    }
}

struct QuickRestoreRow: View {
    @ObservedObject var model: Model
    let item: QuickRestoreItem
    func slotText(_ slot: Int?) -> String { slot.map{lk("桌面 %@", "\($0)")} ?? lk("另一块屏幕") }
    var secondary: (String,Color)? {
        if let r=model.quickResults[item.savedIndex],r.outcome != .verified { return (r.detail,Tone.warning.color) }
        switch item.state {
        case .ready: return item.moveSpace ? (lk("%@ → 桌面 %@", "\(slotText(item.currentSlot))", "\(item.targetSlot ?? 0)"),.secondary) : (lk("桌面 %@ 内调整位置和大小", "\(item.currentSlot ?? 0)"),.secondary)
        case .alreadyInPlace: return nil
        default: return item.reason.isEmpty ? nil : (item.reason,.secondary)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                AppIconView(bundleID:item.bundleID,size:30)
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:6) {
                        Text(model.appName(item.bundleID)).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(item.savedTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let secondary { Text(secondary.0).font(.caption).foregroundStyle(secondary.1).lineLimit(2) }
                }
                Spacer(minLength:8)
                if let r=model.quickResults[item.savedIndex] {
                    Pill(text:r.outcome == .verified ? lk("已恢复") : lk("未通过"),systemImage:r.outcome == .verified ? "checkmark" : "exclamationmark",tone:r.outcome == .verified ? .success : .warning)
                } else {
                    let b=item.badge
                    Pill(text:b.text,systemImage:b.icon,tone:b.tone)
                }
            }
            if item.state == .needsConfirmation || (model.quickChoices[item.savedIndex] != nil && item.state != .skippedByUser) {
                HStack {
                    Picker(lk("选择窗口"),selection:Binding<String>(get:{
                        switch model.quickChoices[item.savedIndex] { case .window(let t)?: return t; case .skip?: return "skip"; case nil: return "auto" }
                    },set:{ value in
                        model.setQuickChoice(item.savedIndex,value=="auto" ? nil : (value=="skip" ? .skip : .window(value)))
                    })) {
                        Text(lk("请选择对应的窗口…")).tag("auto")
                        ForEach(item.candidates) { c in
                            Text("\(c.title.isEmpty ? lk("（无标题）") : BrowserTitles.choiceLabel(c.title,bundleID:item.bundleID)) · \(slotText(c.slot))").tag(c.token)
                        }
                        Text(lk("本次跳过")).tag("skip")
                    }.labelsHidden().frame(maxWidth:380)
                    if item.state == .needsConfirmation,let token=item.chosenToken,model.quickChoices[item.savedIndex]==nil {
                        Button(lk("就是这个")) { model.setQuickChoice(item.savedIndex,.window(token)) }
                    }
                    Spacer()
                }.padding(.leading,42).controlSize(.small)
            }
        }
        .padding(.horizontal,14).padding(.vertical,10)
        .contentShape(Rectangle())
        .help(item.reason)
        .contextMenu {
            if item.state != .skippedByUser { Button(lk("本次跳过")) { model.setQuickChoice(item.savedIndex,.skip) } }
            if model.quickChoices[item.savedIndex] != nil { Button(lk("恢复自动匹配")) { model.setQuickChoice(item.savedIndex,nil) } }
        }
    }
}
