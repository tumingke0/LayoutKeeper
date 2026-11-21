// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import SwiftUI
import LayoutCore
import MacAdapters

extension Model {
    var currentExternalMonitor: ConnectedMonitor? { externalMonitors.count==1 ? externalMonitors[0] : nil }
    /// The display configuration this app saves/restores for right now: the single
    /// external monitor when one is attached, else the built-in screen alone
    /// (identity `.builtInOnly`, key "builtin-only"). Nil only with two or more
    /// external monitors (unsupported, as before) or no built-in display.
    var currentConfiguration: (identity: MonitorIdentity, displayToken: String)? {
        if let m=currentExternalMonitor { return (m.identity,m.runtimeDisplayToken) }
        guard externalMonitors.isEmpty,let token=builtInDisplayToken else { return nil }
        return (.builtInOnly,token)
    }
    /// The same target display must still be present, including in built-in-only mode.
    func configurationStillCurrent(_ config: (identity: MonitorIdentity, displayToken: String)) -> Bool {
        let current=MonitorRecognition.externalMonitors()
        if config.identity.isBuiltInOnly { return current.isEmpty && builtInDisplayToken==config.displayToken }
        return current.count==1 && current[0].identity.key==config.identity.key && current[0].runtimeDisplayToken==config.displayToken
    }
    func monitorRecordURL(_ monitor: MonitorIdentity) throws -> URL {
        guard let directory=layoutDirectory else { throw LayoutError.unsupported }
        return directory.appendingPathComponent("screens",isDirectory:true).appendingPathComponent("\(monitor.key).json")
    }
    /// Refreshes the record for the current display configuration (see
    /// `currentConfiguration`). `externalRecord` keeps its name but now holds that
    /// configuration's record: the external monitor's, or the built-in-only layout's.
    func refreshExternalMonitor() {
        externalMonitors=MonitorRecognition.externalMonitors(); refreshAuthorization(); externalRecord=nil
        defer { reloadLibrary() }
        guard let config=currentConfiguration else {captureInspection=nil;captureInspectionMessage="";captureInspectionMonitorKey=nil;externalMessage=externalMonitors.isEmpty ? lk("接上外接屏后，我会自动识别它。") : lk("当前版本只支持内置屏加一个外接屏，请只连接一个外接屏。");return}
        let identity=config.identity
        if captureInspectionMonitorKey != identity.key {captureInspection=nil;captureInspectionMessage="";captureInspectionMonitorKey=nil}
        do {
            let url=try monitorRecordURL(identity)
            if FileManager.default.fileExists(atPath:url.path) {
                let record=try MonitorLayoutStore.load(from:url)
                guard record.monitor.key==identity.key else { throw LayoutError.invalidProfile }
                externalRecord=record
                externalMessage=record.captureSummary + (record.profile.windows.contains{$0.desktopIndex==nil} ? lk("\n这份布局由旧版本保存，缺少桌面顺序：请重新保存一次，才能一键恢复。") : "")
            } else if identity.isBuiltInOnly { externalMessage=lk("仅用内屏，还没有保存过内屏布局。先把窗口摆好，再点「保存布局」。") }
            else { externalMessage=lk("这块屏幕（%@）还没有保存过布局。先把窗口摆好，再点「保存布局」。记录跟随屏幕硬件识别，不需要选择家或公司。", "\(identity.name)") }
        } catch { externalMessage=lk("这份布局暂时无法读取，可以重新保存。"); message=lk("布局读取：%@", "\(error)") }
    }
    func inspectExternalCapture() {
        guard !restoring,!checkingCapture,let config=currentConfiguration else{return}
        refreshAuthorization();guard trusted else{captureInspectionMessage=accessState.guidance;return}
        checkingCapture=true;let started=Date();defer{checkingCapture=false;refreshAuthorization()}
        captureInspectionMessage=lk("正在只读检查可保存窗口…")
        do {
            let snapshot=try currentLayoutSnapshot(inspectionBudget:10)
            guard configurationStillCurrent(config) else{throw LayoutError.readbackUnavailable}
            let assessed=try ExternalLayoutCapture.assess(monitor:config.identity,displayToken:config.displayToken,snapshot:snapshot,report:windows.latestCaptureReport)
            guard let report=assessed.record.captureReport else{throw LayoutError.readbackUnavailable}
            windows.applyCaptureDecisions(assessed.decisions);captureTrace=windows.captureTrace
            captureInspection=report;captureInspectionMonitorKey=config.identity.key;captureInspectionMessage=lk("只读检查完成，没有保存布局。")+report.summary
            message=report.json()+traceText
        } catch {
            var report=windows.latestCaptureReport
            if report.measuredAt<started {report=CapturePipelineReport();report.globalReasons["checkFailedBeforeScan"]=1;report.finish()}
            captureTrace=windows.captureTrace
            captureInspection=report;captureInspectionMonitorKey=config.identity.key;captureInspectionMessage=lk("只读检查未完成。")+ExternalSaveMessage.failure(error:error,phase:.readWindows)
            message=report.json()+traceText
        }
    }
    /// `confirmOverwrite` false (menu bar / hotkey) skips the dialog; overwriting still archives the old version in history.
    /// Saves the current display configuration: the external monitor's layout when one is
    /// attached, else the built-in screen's layout ("builtin-only").
    @discardableResult func saveCurrentLayout(confirmOverwrite: Bool = true) -> SaveOutcome {
        guard !restoring,!checkingCapture else { return .failed(lk("正在处理上一个操作")) }
        guard let config=currentConfiguration else { return .failed(lk("没有可保存的显示配置（目前只支持内置屏加一个外接屏）")) }
        refreshAuthorization()
        guard trusted else { externalMessage=accessState.guidance; return .failed(lk("需要辅助功能权限")) }
        defer { refreshAuthorization() }
        var replaced=false
        do {
            let url=try monitorRecordURL(config.identity)
            if FileManager.default.fileExists(atPath:url.path) {
                replaced=true
                if confirmOverwrite {
                    let alert=NSAlert(); alert.messageText=config.identity.isBuiltInOnly ? lk("更新内屏布局？") : lk("更新这块屏幕的布局？")
                    alert.informativeText=lk("新布局会成为当前版本，旧版本存入「历史版本」（保留最近 10 个）。保存只读取窗口，不会恢复或移动窗口。")
                    alert.addButton(withTitle:lk("更新布局")); alert.addButton(withTitle:lk("取消"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
                }
            }
        } catch { externalMessage=lk("无法确定保存位置，本次没有保存。"); return .failed(externalMessage) }
        captureInspection=nil;captureInspectionMessage=""
        var phase=ExternalSavePhase.readWindows
        do {
            let s=try currentLayoutSnapshot()
            phase = .validateScreen
            guard configurationStillCurrent(config) else { throw LayoutError.readbackUnavailable }
            phase = .capture
            let assessed=try ExternalLayoutCapture.assess(monitor:config.identity,displayToken:config.displayToken,snapshot:s,report:windows.latestCaptureReport)
            windows.applyCaptureDecisions(assessed.decisions);captureTrace=windows.captureTrace
            var record=assessed.record
            if let chrome=ChromeProfiles.load() { record.profile.windows=chrome.tag(record.profile.windows) }
            captureInspection=record.captureReport;captureInspectionMonitorKey=config.identity.key
            guard !record.profile.windows.isEmpty else {
                actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("没有读到可保存的窗口"),tone:.warning)
                externalMessage=windows.issues.isEmpty ? (config.identity.isBuiltInOnly ? lk("没有读到可保存的内屏窗口。请在内屏打开普通软件窗口，再保存。") : lk("没有读到可保存的外接屏窗口。请在外接屏打开普通软件窗口，再保存。")) : lk("没有读到可保存的外接屏窗口。本次有窗口信息读取失败，可以稍后重试。")
                message=record.captureReport?.json() ?? "{}";return .failed(lk("没有读到可保存的窗口"))
            }
            phase = .writeRecord
            let url=try monitorRecordURL(config.identity)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            record.coverage?.readIssueCount=windows.issues.count
            guard let library=screenLibrary,library.currentURL(config.identity.key)==url else { throw LayoutError.unsupported }
            try library.save(record)
            externalRecord=record
            selectedScreenKey=config.identity.key; reloadLibrary()
            externalMessage=record.captureSummary
            message=record.captureReport?.json() ?? "{}"
            actionNote=ActionNote(icon:"checkmark.circle.fill",text:lk("已保存 %@ 个窗口", "\(record.profile.windows.count)")+(replaced ? lk(" · 旧版本已存入历史") : ""),tone:.success)
            return .saved(count:record.profile.windows.count,replaced:replaced)
        } catch {
            externalMessage=ExternalSaveMessage.failure(error:error,phase:phase)
            actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:externalMessage,tone:.warning)
            message=([lk("保存布局：%@", "\(error)")]+windows.issues).joined(separator:"\n")
            return .failed(externalMessage)
        }
    }
    /// Diagnostics-only text; the trace is never part of the saved record.
    var traceText:String {
        guard !captureTrace.isEmpty else{return ""}
        return lk("\n\n逐窗口追踪（仅本次运行，不写入布局文件）：\n")+captureTrace.map(\.line).joined(separator:"\n")
    }
    var lastMonitorSave: String {
        guard let externalRecord else { return lk("尚未保存") }
        let formatter=DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        return lk("已保存 %@ 个可读取窗口 · %@", "\(externalRecord.profile.windows.count)", "\(formatter.string(from:externalRecord.savedAt))")
    }
}

/// Capture statistics (no window titles). Shown in Settings → 诊断.
struct CaptureStatsView: View {
    @ObservedObject var model: Model
    let report: CapturePipelineReport
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(report.summary).font(.callout)
            Text(lk("统计时间 %@，读取耗时 %@ 毫秒。CG 候选只用于比对，未知条目不算已保存。", "\(report.measuredAt.formatted(date:.omitted,time:.standard))", "\(report.elapsedMilliseconds)")).font(.caption).foregroundStyle(.secondary)
            if !report.globalReasons.isEmpty {Text(report.globalReasons.keys.sorted().map{lk("%@：%@", "\($0)", "\(report.globalReasons[$0] ?? 0)")}.joined(separator:lk("；"))).font(.caption).foregroundStyle(.orange)}
            ForEach(report.spaces,id:\.index) {space in
                Text(lk("桌面 %@%@：CG 候选 %@，未对应 AX %@，可保存 %@", "\(space.index)", "\(space.active ? lk("（统计时活动）") : "")", "\(space.cgCandidates)", "\(space.cgNotInAX)", "\(space.captured)")).font(.caption)
            }
            DisclosureGroup(lk("按应用")) {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(report.applications.sorted{$0.bundleID<$1.bundleID},id:\.bundleID) {app in
                        VStack(alignment:.leading,spacing:3) {
                            Text(app.bundleID).font(.caption.bold())
                            Text(lk("AX 列表 %@ ＋聚焦/主窗口 %@ ＋其他桌面找回 %@/%@；非候选 %@", "\(app.count(.axEnumerated))", "\(app.count(.axFocusedOrMainAdded))", "\(app.count(.remoteTokenResolved))", "\(app.count(.remoteTokenWanted))", "\(app.count(.cgNonCandidate))")).font(.caption)
                            Text(lk("窗口 ID %@ → CG 匹配 %@ → 可读 %@ → 外屏 %@ → 捕获 %@", "\(app.count(.windowIDResolved))", "\(app.count(.cgOwnerMatched))", "\(app.count(.axReadable))", "\(app.count(.selectedDisplay))", "\(app.count(.captured))")).font(.caption)
                            if !app.reasons.isEmpty {Text(app.reasons.keys.sorted().map{lk("%@：%@", "\(CaptureReason(rawValue:$0)?.label ?? $0)", "\(app.reasons[$0] ?? 0)")}.joined(separator:lk("；"))).font(.caption).foregroundStyle(.orange)}
                            ForEach(Array(app.axErrors.enumerated()),id:\.offset) {_,event in Text(lk("%@：AXError %@，%@ 次", "\(event.operation)", "\(event.code)", "\(event.count)")).font(.caption)}
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.font(.caption)
            if !model.captureTrace.isEmpty {
                DisclosureGroup(lk("逐窗口追踪（仅本次运行，不写入布局文件）")) {
                    VStack(alignment:.leading,spacing:2) {
                        ForEach(Array(model.captureTrace.enumerated()),id:\.offset) {_,entry in Text(entry.line).font(.caption.monospaced()).textSelection(.enabled)}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.font(.caption)
            }
        }
    }
}
