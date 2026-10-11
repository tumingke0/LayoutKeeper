// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters
import SpaceProbe

struct ControlledDispatchFailure: Error,CustomStringConvertible {
    let description: String
}
extension Model {
    /// Capability-based (macOS 26+ and the bridged move/readback symbols resolve); not a build allow-list.
    var crossSpaceSupport: CrossSpaceSupport {
        if let cachedCrossSpaceSupport { return cachedCrossSpaceSupport }
        let os=ProcessInfo.processInfo.operatingSystemVersion
        let build=NSDictionary(contentsOfFile:"/System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String ?? ""
        var raw=SPCrossSpaceSymbols(); SPProbeCrossSpaceSymbols(&raw)
        let probe=CrossSpaceProbe(skyLightLoaded:raw.skyLightLoaded != 0,moveOperationClass:raw.moveOperationClass != 0,moveOperationABI:raw.moveOperationABI != 0,
                                  membershipRead:raw.membershipRead != 0,managedDisplaySpaces:raw.managedDisplaySpaces != 0,mainConnection:raw.mainConnection != 0)
        var support=CrossSpaceGate.decide(major:os.majorVersion,minor:os.minorVersion,patch:os.patchVersion,build:build,probe:probe)
        // The native dispatcher applies its own copy of the gate; never enable the UI if they disagree.
        if support.enabled && SPControlledBridgeAvailable() != 1 { support = .unavailable(reason:"系统接口检测结果不一致，已关闭跨桌面移动。") }
        cachedCrossSpaceSupport=support
        return support
    }
    var crossSpaceEnabled: Bool { crossSpaceSupport.enabled }
    func makeControlledMover(_ permits: [SpaceMovePermit],fixtureOnly: Bool = false) -> ControlledSpaces {
        ControlledSpaces(windows:windows,permits:permits,dispatch:{ proof,request in
            if fixtureOnly {
                guard proof.claim.axPID==getpid(),proof.selector.title=="LayoutKeeper Fixture 1",
                      self.fixtures.contains(where:{$0.windowNumber==Int(proof.claim.windowID) && $0.title=="LayoutKeeper Fixture 1" && $0.isVisible && !$0.isMiniaturized}) else { throw LayoutError.readbackUnavailable }
            }
            var detail=[CChar](repeating:0,count:512)
            let code=proof.claim.bundleID.withCString { bundle in
                (proof.selector.document ?? "").withCString { document in
                    proof.selector.title.withCString { title in
                        request.sourceDisplay.withCString { sourceDisplay in
                            request.targetDisplay.withCString { targetDisplay in
                                SPDispatchVerifiedWindow(proof.element,proof.claim.axPID,proof.claim.windowID,proof.claim.processStartedAt.timeIntervalSince1970,bundle,document,title,request.source,request.target,sourceDisplay,targetDisplay,&detail,512)
                            }
                        }
                    }
                }
            }
            guard code==0 else { throw ControlledDispatchFailure(description:String(cString:detail)) }
        })
    }
    func prepareFixtureSpacePreview() {
        guard !restoring else { return }
        fixtureSpacePlan=nil;fixtureSpaceSnapshot=nil;fixtureSpaceResults=[]
        refreshAuthorization()
        guard trusted,crossSpaceEnabled,let fixture=fixtures.first,fixture.isVisible,!fixture.isMiniaturized else { fixtureSpaceMessage="请先打开本应用的空白演示窗口，并保持已授权和受支持的系统构建。";return }
        do {
            var snapshot=try windows.scan(onlyPID:getpid())
            snapshot.windows=snapshot.windows.filter{$0.token=="\(getpid()):\(fixture.windowNumber)" && $0.selector.title=="LayoutKeeper Fixture 1"}
            guard snapshot.windows.count==1,let window=snapshot.windows.first,window.ordinary,!window.fullScreen,!window.minimized,window.spaceIDs.count==1,
                  let source=snapshot.spaces.first(where:{$0.id==window.spaceIDs[0] && $0.kind == .ordinary}),
                  let display=snapshot.displays.first(where:{$0.token==source.displayToken}),
                  let target=snapshot.spaces.first(where:{$0.displayToken==source.displayToken && $0.kind == .ordinary && $0.id != source.id}) else { throw LayoutError.readbackUnavailable }
            let saved=SavedWindow(selector:window.selector,displayRole:display.role,desktopLabel:"空白跨桌面验收",normalizedFrame:window.frame.normalized(in:display.visible))
            fixtureSpaceSnapshot=snapshot
            fixtureSpacePlan=RestorePlan(session:snapshot.session,topology:snapshot.topology,entries:[PlanEntry(saved:saved,status:.ready,reason:"仅空白演示窗口：源普通桌面 → 同屏另一普通桌面 → 返回源桌面",window:window,targetSpace:target.id,targetDisplay:display.token,targetFrame:window.frame)])
            fixtureSpaceMessage="只对本应用空白窗口测试一次桌面往返，逐次回读。不会处理真实工作窗口，也不创建或切换桌面。"
        } catch { fixtureSpaceMessage="空白窗口身份或同屏两个普通桌面无法确认，没有生成验收计划：\(error)" }
    }
    func runFixtureSpaceRoundTrip() {
        guard !restoring,let plan=fixtureSpacePlan,let snapshot=fixtureSpaceSnapshot,
              plan.entries.count==1,let window=plan.entries[0].window,let target=plan.entries[0].targetSpace,let display=plan.entries[0].targetDisplay,
              let fixture=fixtures.first,fixture.isVisible,window.token=="\(getpid()):\(fixture.windowNumber)",window.selector.title=="LayoutKeeper Fixture 1" else { return }
        let alert=NSAlert();alert.messageText="仅测试这个空白窗口的桌面往返？"
        alert.informativeText="将本应用的 LayoutKeeper Fixture 1 移到预览目标普通桌面，回读后立即返回原桌面并验证原位置与大小。任何失败会停止并尝试回滚；不操作其他应用或工作窗口。"
        alert.addButton(withTitle:"确认空白窗口往返");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        refreshAuthorization();guard trusted else { fixtureSpaceMessage=accessState.guidance;return }
        restoring=true;windows.writesApproved=true
        defer { restoring=false;windows.writesApproved=false;fixtureSpacePlan=nil }
        do {
            let permits=[try SpaceMovePermit(window:window,targetSpace:target,targetDisplay:display,snapshot:snapshot)]
            let mover=makeControlledMover(permits,fixtureOnly:true);var journalURL: URL?
            func persist(_ journal: RestoreJournal) throws {
                if let url=journalURL { try RestoreJournalStore.update(journal,at:url) }
                else { guard let directory=guidedDirectory else { throw LayoutError.unsupported };journalURL=try RestoreJournalStore.create(journal,in:directory.appendingPathComponent("transactions")) }
            }
            let report=ManualRestorer.execute(plan,windows:windows,spaces:mover,approved:true,polls:20,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))},persist:persist)
            fixtureSpaceResults=report.results;fixtureSpaceJournal=report.journal;fixtureSpaceJournalURL=journalURL;fixtureSpacePermits=permits
            guard report.results.count==1,report.results[0].outcome == .verified,let journal=report.journal else { fixtureSpaceMessage="空白窗口未通过目标桌面回读，请检查逐项结果与回滚状态。";return }
            let returned=ManualRestorer.undo(journal,windows:windows,spaces:mover,approved:true,polls:20,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))},persist:persist)
            fixtureSpaceJournal=returned.journal;fixtureSpaceResults+=returned.results
            fixtureSpaceMessage=returned.results.count==1 && returned.results[0].outcome == .verified ? "空白窗口往返完成：目标和原桌面、原位置与大小均已回读。此结果不能外推到其他应用窗口。" : "目标桌面已确认，返回阶段未通过验证；请检查实际空白窗口并重试撤销。"
            if !report.persistenceIssues.isEmpty || !returned.persistenceIssues.isEmpty { fixtureSpaceMessage+="操作日志有更新失败，不能视为完整验收通过。" }
        } catch { fixtureSpaceMessage="空白测试审批范围或日志无法冻结，没有开始：\(error)" }
    }
    func undoFixtureSpaceTest() {
        guard !restoring,let journal=fixtureSpaceJournal,journal.canUndo,let url=fixtureSpaceJournalURL else { return }
        let alert=NSAlert();alert.messageText="重试撤销空白窗口测试？";alert.informativeText="只尝试返回这次验收的空白窗口；身份、拓扑或后续位置改变时停止。"
        alert.addButton(withTitle:"撤销空白测试");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        refreshAuthorization();guard trusted else { return }
        restoring=true;windows.writesApproved=true;defer { restoring=false;windows.writesApproved=false }
        let report=ManualRestorer.undo(journal,windows:windows,spaces:makeControlledMover(fixtureSpacePermits,fixtureOnly:true),approved:true,polls:20,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))},persist:{try RestoreJournalStore.update($0,at:url)})
        fixtureSpaceJournal=report.journal;fixtureSpaceResults=report.results;fixtureSpaceMessage="撤销尝试结束，请检查空白窗口与逐项回读结果。"
    }
}
struct FixtureSpaceSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("仅空白窗口跨桌面验收").font(.title2.bold())
            Text("只测试 LayoutKeeper 创建的一个空白窗口，确认后目标回读，再返回原桌面。默认启动和预览均不派发移窗。")
            if let entry=model.fixtureSpacePlan?.entries.first {
                Text("窗口：空白演示窗口")
                Text("本次源 Space \(entry.window?.spaceIDs.first ?? 0) → 目标 Space \(entry.targetSpace ?? 0) → 返回源 Space")
                Text("原位置：\(model.frameDescription(entry.window?.frame))")
            }
            ForEach(Array(model.fixtureSpaceResults.enumerated()),id:\.offset) { _,result in Text(result.detail).font(.callout) }
            Text(model.fixtureSpaceMessage).foregroundStyle(.secondary)
            HStack {
                Button("确认空白窗口往返") { model.runFixtureSpaceRoundTrip() }.disabled(model.fixtureSpacePlan==nil || !model.trusted)
                Button("重试撤销空白测试") { model.undoFixtureSpaceTest() }.disabled(model.fixtureSpaceJournal?.canUndo != true || !model.trusted)
                Spacer();Button("关闭") { dismiss() }
            }
        }.padding(24).frame(width:680).disabled(model.restoring)
    }
}
