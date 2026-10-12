// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import SwiftUI
import LayoutCore
import MacAdapters

extension Model {
    var currentExternalMonitor: ConnectedMonitor? { externalMonitors.count==1 ? externalMonitors[0] : nil }
    func monitorRecordURL(_ monitor: MonitorIdentity) throws -> URL {
        guard let directory=layoutDirectory else { throw LayoutError.unsupported }
        return directory.appendingPathComponent("screens",isDirectory:true).appendingPathComponent("\(monitor.key).json")
    }
    func refreshExternalMonitor() {
        externalMonitors=MonitorRecognition.externalMonitors(); refreshAuthorization(); externalRecord=nil
        defer { reloadLibrary() }
        guard let monitor=currentExternalMonitor else {captureInspection=nil;captureInspectionMessage="";captureInspectionMonitorKey=nil;externalMessage=externalMonitors.isEmpty ? "接上外接屏后，我会自动识别它。" : "当前版本只支持内置屏加一个外接屏，请只连接一个外接屏。";return}
        if captureInspectionMonitorKey != monitor.identity.key {captureInspection=nil;captureInspectionMessage="";captureInspectionMonitorKey=nil}
        do {
            let url=try monitorRecordURL(monitor.identity)
            if FileManager.default.fileExists(atPath:url.path) {
                let record=try MonitorLayoutStore.load(from:url)
                guard record.monitor.key==monitor.identity.key else { throw LayoutError.invalidProfile }
                externalRecord=record
                externalMessage=record.captureSummary + (record.profile.windows.contains{$0.desktopIndex==nil} ? "\n这份布局由旧版本保存，缺少桌面顺序：请重新保存一次，才能一键恢复。" : "")
            } else { externalMessage="这块屏幕（\(monitor.identity.name)）还没有保存过布局。先把窗口摆好，再点「保存布局」。记录跟随屏幕硬件识别，不需要选择家或公司。" }
        } catch { externalMessage="这份布局暂时无法读取，可以重新保存。"; message="外接屏布局读取：\(error)" }
    }
    func inspectExternalCapture() {
        guard !restoring,!checkingCapture,let monitor=currentExternalMonitor else{return}
        refreshAuthorization();guard trusted else{captureInspectionMessage=accessState.guidance;return}
        checkingCapture=true;let started=Date();defer{checkingCapture=false;refreshAuthorization()}
        captureInspectionMessage="正在只读检查可保存窗口…"
        do {
            let snapshot=try externalLayoutSnapshot(inspectionBudget:10)
            let current=MonitorRecognition.externalMonitors()
            guard current.count==1,current[0].identity.key==monitor.identity.key,current[0].runtimeDisplayToken==monitor.runtimeDisplayToken else{throw LayoutError.readbackUnavailable}
            let assessed=try ExternalLayoutCapture.assess(monitor:monitor.identity,displayToken:monitor.runtimeDisplayToken,snapshot:snapshot,report:windows.latestCaptureReport)
            guard let report=assessed.record.captureReport else{throw LayoutError.readbackUnavailable}
            windows.applyCaptureDecisions(assessed.decisions);captureTrace=windows.captureTrace
            captureInspection=report;captureInspectionMonitorKey=monitor.identity.key;captureInspectionMessage="只读检查完成，没有保存布局。"+report.summary
            message=report.json()+traceText
        } catch {
            var report=windows.latestCaptureReport
            if report.measuredAt<started {report=CapturePipelineReport();report.globalReasons["checkFailedBeforeScan"]=1;report.finish()}
            captureTrace=windows.captureTrace
            captureInspection=report;captureInspectionMonitorKey=monitor.identity.key;captureInspectionMessage="只读检查未完成。"+ExternalSaveMessage.failure(error:error,phase:.readWindows)
            message=report.json()+traceText
        }
    }
    /// `confirmOverwrite` false (menu bar / hotkey) skips the dialog; overwriting still archives the old version in history.
    @discardableResult func saveExternalLayout(confirmOverwrite: Bool = true) -> SaveOutcome {
        guard !restoring,!checkingCapture,let monitor=currentExternalMonitor else { return .failed(currentExternalMonitor == nil ? "未连接外接屏" : "正在处理上一个操作") }
        refreshAuthorization()
        guard trusted else { externalMessage=accessState.guidance; return .failed("需要辅助功能权限") }
        defer { refreshAuthorization() }
        var replaced=false
        do {
            let url=try monitorRecordURL(monitor.identity)
            if FileManager.default.fileExists(atPath:url.path) {
                replaced=true
                if confirmOverwrite {
                    let alert=NSAlert(); alert.messageText="更新这块屏幕的布局？"
                    alert.informativeText="新布局会成为当前版本，旧版本存入「历史版本」（保留最近 10 个）。保存只读取窗口，不会恢复或移动窗口。"
                    alert.addButton(withTitle:"更新布局"); alert.addButton(withTitle:"取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
                }
            }
        } catch { externalMessage="无法确定保存位置，本次没有保存。"; return .failed(externalMessage) }
        captureInspection=nil;captureInspectionMessage=""
        var phase=ExternalSavePhase.readWindows
        do {
            let s=try externalLayoutSnapshot()
            phase = .validateScreen
            let current=MonitorRecognition.externalMonitors()
            guard current.count==1,current[0].identity.key==monitor.identity.key,current[0].runtimeDisplayToken==monitor.runtimeDisplayToken else { throw LayoutError.readbackUnavailable }
            phase = .capture
            let assessed=try ExternalLayoutCapture.assess(monitor:monitor.identity,displayToken:monitor.runtimeDisplayToken,snapshot:s,report:windows.latestCaptureReport)
            windows.applyCaptureDecisions(assessed.decisions);captureTrace=windows.captureTrace
            var record=assessed.record
            captureInspection=record.captureReport;captureInspectionMonitorKey=monitor.identity.key
            guard !record.profile.windows.isEmpty else {
                actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:"没有读到可保存的窗口",tone:.warning)
                externalMessage=windows.issues.isEmpty ? "没有读到可保存的外接屏窗口。请在外接屏打开普通软件窗口，再保存。" : "没有读到可保存的外接屏窗口。本次有窗口信息读取失败，可以稍后重试。"
                message=record.captureReport?.json() ?? "{}";return .failed("没有读到可保存的窗口")
            }
            phase = .writeRecord
            let url=try monitorRecordURL(monitor.identity)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            record.coverage?.readIssueCount=windows.issues.count
            guard let library=screenLibrary,library.currentURL(monitor.identity.key)==url else { throw LayoutError.unsupported }
            try library.save(record)
            externalRecord=record
            selectedScreenKey=monitor.identity.key; reloadLibrary()
            externalMessage=record.captureSummary
            message=record.captureReport?.json() ?? "{}"
            actionNote=ActionNote(icon:"checkmark.circle.fill",text:"已保存 \(record.profile.windows.count) 个窗口"+(replaced ? " · 旧版本已存入历史" : ""),tone:.success)
            return .saved(count:record.profile.windows.count,replaced:replaced)
        } catch {
            externalMessage=ExternalSaveMessage.failure(error:error,phase:phase)
            actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:externalMessage,tone:.warning)
            message=(["外接屏保存：\(error)"]+windows.issues).joined(separator:"\n")
            return .failed(externalMessage)
        }
    }
    /// Diagnostics-only text; the trace is never part of the saved record.
    var traceText:String {
        guard !captureTrace.isEmpty else{return ""}
        return "\n\n逐窗口追踪（仅本次运行，不写入布局文件）：\n"+captureTrace.map(\.line).joined(separator:"\n")
    }
    var lastMonitorSave: String {
        guard let externalRecord else { return "尚未保存" }
        let formatter=DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        return "已保存 \(externalRecord.profile.windows.count) 个可读取窗口 · \(formatter.string(from:externalRecord.savedAt))"
    }
}

/// Capture statistics (no window titles). Shown in Settings → 诊断.
struct CaptureStatsView: View {
    @ObservedObject var model: Model
    let report: CapturePipelineReport
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(report.summary).font(.callout)
            Text("统计时间 \(report.measuredAt.formatted(date:.omitted,time:.standard))，读取耗时 \(report.elapsedMilliseconds) 毫秒。CG 候选只用于比对，未知条目不算已保存。").font(.caption).foregroundStyle(.secondary)
            if !report.globalReasons.isEmpty {Text(report.globalReasons.keys.sorted().map{"\($0)：\(report.globalReasons[$0] ?? 0)"}.joined(separator:"；")).font(.caption).foregroundStyle(.orange)}
            ForEach(report.spaces,id:\.index) {space in
                Text("桌面 \(space.index)\(space.active ? "（统计时活动）" : "")：CG 候选 \(space.cgCandidates)，未对应 AX \(space.cgNotInAX)，可保存 \(space.captured)").font(.caption)
            }
            DisclosureGroup("按应用") {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(report.applications.sorted{$0.bundleID<$1.bundleID},id:\.bundleID) {app in
                        VStack(alignment:.leading,spacing:3) {
                            Text(app.bundleID).font(.caption.bold())
                            Text("AX 列表 \(app.count(.axEnumerated)) ＋聚焦/主窗口 \(app.count(.axFocusedOrMainAdded)) ＋其他桌面找回 \(app.count(.remoteTokenResolved))/\(app.count(.remoteTokenWanted))；非候选 \(app.count(.cgNonCandidate))").font(.caption)
                            Text("窗口 ID \(app.count(.windowIDResolved)) → CG 匹配 \(app.count(.cgOwnerMatched)) → 可读 \(app.count(.axReadable)) → 外屏 \(app.count(.selectedDisplay)) → 捕获 \(app.count(.captured))").font(.caption)
                            if !app.reasons.isEmpty {Text(app.reasons.keys.sorted().map{"\(CaptureReason(rawValue:$0)?.label ?? $0)：\(app.reasons[$0] ?? 0)"}.joined(separator:"；")).font(.caption).foregroundStyle(.orange)}
                            ForEach(Array(app.axErrors.enumerated()),id:\.offset) {_,event in Text("\(event.operation)：AXError \(event.code)，\(event.count) 次").font(.caption)}
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.font(.caption)
            if !model.captureTrace.isEmpty {
                DisclosureGroup("逐窗口追踪（仅本次运行，不写入布局文件）") {
                    VStack(alignment:.leading,spacing:2) {
                        ForEach(Array(model.captureTrace.enumerated()),id:\.offset) {_,entry in Text(entry.line).font(.caption.monospaced()).textSelection(.enabled)}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.font(.caption)
            }
        }
    }
}
