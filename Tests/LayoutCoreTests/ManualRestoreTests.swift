// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class ManualRestoreTests: XCTestCase {
    let monitor=MonitorIdentity(vendor:1,model:2,serial:3,name:"测试外屏")
    func fixture() -> (MemoryWindows,MonitorLayoutRecord) {
        let windows=[ObservedWindow(token:"100:1",selector:WindowSelector(bundleID:"test.editor",document:"file:///fixture",title:"旧标题"),frame:Rect(1200,40,500,400),spaceIDs:[72])]
        let snapshot=Snapshot(session:UUID(),topology:"stable",displays:[Display(token:"external",name:"测试外屏",role:.external,visible:Rect(1200,0,1600,1000))],spaces:[Space(id:72,displayToken:"external",active:true),Space(id:73,displayToken:"external")],windows:windows)
        let profile=Profile(location:"测试",windows:[SavedWindow(selector:windows[0].selector,displayRole:.external,desktopLabel:"组甲",normalizedFrame:Rect(0.25,0.1,0.4,0.5))])
        return (MemoryWindows(snapshot),MonitorLayoutRecord(monitor:monitor,profile:profile))
    }
    func plan(_ b: MemoryWindows,_ r: MonitorLayoutRecord,groups: [String:UInt64] = ["组甲":72]) throws -> RestorePlan {
        try MonitorRestorePlanner.plan(record:r,monitor:monitor,displayToken:"external",snapshot:b.state,groupSpaces:groups)
    }
    func testUnmappedLogicalGroupRequiresExplicitCurrentDesktop() throws {
        let (b,r)=fixture(); XCTAssertEqual(try plan(b,r,groups:[:]).entries[0].status,.blocked)
    }
    func testSameSpaceUsesDocumentIdentityEvenAfterTitleChanges() throws {
        let (b,r)=fixture(); b.state.windows[0].selector.title="新标题"
        XCTAssertEqual(try plan(b,r).entries[0].status,.ready)
    }
    func testUnknownMembershipIsSkippedAndCrossSpaceIsBlocked() throws {
        let (b,r)=fixture(); b.state.windows[0].spaceIDs=[]
        XCTAssertEqual(try plan(b,r).entries[0].status,.skipped)
        b.state.windows[0].spaceIDs=[72,73]; XCTAssertEqual(try plan(b,r).entries[0].status,.skipped)
        b.state.windows[0].spaceIDs=[72]; XCTAssertEqual(try plan(b,r,groups:["组甲":73]).entries[0].status,.blocked)
    }
    func testWrongMonitorCannotProduceRestorePlan() throws {
        let (b,r)=fixture()
        XCTAssertThrowsError(try MonitorRestorePlanner.plan(record:r,monitor:MonitorIdentity(vendor:1,model:2,serial:4,name:"别的屏"),displayToken:"external",snapshot:b.state,groupSpaces:["组甲":72]))
    }
    func testDuplicateDocumentIsSkipped() throws {
        let (b,r)=fixture(); var duplicate=b.state.windows[0]; duplicate.token="100:2"; b.state.windows.append(duplicate)
        XCTAssertEqual(try plan(b,r).entries[0].status,.skipped)
    }
    func testReconnectUsesExplicitNewDisplayAndSpaceIDsWithoutSavedRuntimeIDs() throws {
        let (b,r)=fixture(); b.state.session=UUID(); b.state.topology="reconnected"
        b.state.displays[0].token="replacement-runtime"; b.state.spaces=[Space(id:9002,displayToken:"replacement-runtime",active:true)]
        b.state.windows[0].token="new-pid:42"; b.state.windows[0].spaceIDs=[9002]
        let p=try MonitorRestorePlanner.plan(record:r,monitor:monitor,displayToken:"replacement-runtime",snapshot:b.state,groupSpaces:["组甲":9002])
        XCTAssertEqual(p.entries[0].status,.ready); XCTAssertEqual(p.entries[0].targetSpace,9002)
        XCTAssertEqual(p.entries[0].targetDisplay,"replacement-runtime")
        XCTAssertEqual(p.entries[0].window?.token,"new-pid:42")
    }
    func testCrossSpacePreviewRetainsTargetButCannotExecute() throws {
        let (b,r)=fixture(); let p=try plan(b,r,groups:["组甲":73])
        XCTAssertEqual(p.entries[0].status,.blocked); XCTAssertEqual(p.entries[0].targetSpace,73)
        XCTAssertNotNil(p.entries[0].targetFrame)
        _=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in}); XCTAssertEqual(b.writes,0)
    }
    func testInsufficientDesktopsCannotCollapseDistinctSavedGroups() throws {
        let (b,record)=fixture(); var r=record
        var second=b.state.windows[0]; second.token="100:2"; second.selector=WindowSelector(bundleID:"test.chat",title:"另组")
        b.state.windows.append(second); r.profile.windows.append(SavedWindow(selector:second.selector,displayRole:.external,desktopLabel:"组乙",normalizedFrame:Rect(0.5,0.2,0.3,0.4)))
        b.state.spaces=[b.state.spaces[0]]
        let collapsed=try plan(b,r,groups:["组甲":72,"组乙":72])
        XCTAssertTrue(collapsed.entries.allSatisfy{$0.status == .blocked})
        let missing=try plan(b,r,groups:["组甲":72]); XCTAssertEqual(missing.entries[1].status,.blocked)
    }
    func testRestoreRejectsTargetOutsideDisplayEvenIfPlanWasForged() throws {
        let (b,r)=fixture(); var p=try plan(b,r); p.entries[0].targetFrame=Rect(0,0,500,400)
        _=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in}); XCTAssertEqual(b.writes,0)
    }
    func testReusedPIDAndWindowNumberWithNewProcessStartIsBlocked() throws {
        let (b,r)=fixture()
        func marked(_ window: ObservedWindow,_ start: Double) throws -> ObservedWindow {
            var row=try JSONSerialization.jsonObject(with:JSONEncoder().encode(window)) as! [String:Any]
            row["processStartedAt"]=start
            return try JSONDecoder().decode(ObservedWindow.self,from:JSONSerialization.data(withJSONObject:row))
        }
        b.state.windows[0]=try marked(b.state.windows[0],10)
        let p=try plan(b,r)
        b.state.windows[0]=try marked(b.state.windows[0],20)
        _=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(b.writes,0)
    }
    func testUndoIdentityOrTopologyChangeBlocksWrites() throws {
        let (b,r)=fixture(); let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        b.state.topology="changed"
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results[0].outcome,.blocked); XCTAssertEqual(b.writes,1)
    }
    func testJournalIsDurableBeforeFirstWriteAndUndoRestoresOriginalFrame() throws {
        let (b,r)=fixture(); let original=b.state.windows[0].frame; var persisted=[RestoreJournal]()
        b.beforeWrite={ XCTAssertFalse(persisted.isEmpty); XCTAssertEqual(persisted.last?.entries[0].before.frame,original) }
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{persisted.append($0)})
        XCTAssertEqual(report.results[0].outcome,.verified); XCTAssertEqual(b.writes,1)
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:b,approved:true,persist:{persisted.append($0)})
        XCTAssertEqual(undo.results[0].outcome,.verified); XCTAssertEqual(b.state.windows[0].frame,original)
        XCTAssertEqual(undo.journal?.entries[0].state,.rolledBack)
        let again=ManualRestorer.undo(try XCTUnwrap(undo.journal),windows:b,approved:true,persist:{persisted.append($0)})
        XCTAssertEqual(again.results[0].outcome,.skipped); XCTAssertEqual(b.writes,2)
    }
    func testUserMoveDuringJournalPersistenceIsNotOverwrittenOrRolledBack() throws {
        let (b,r)=fixture(); var calls=0
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in
            calls += 1; if calls==2 { b.state.windows[0].frame.x += 40 }
        })
        XCTAssertEqual(b.writes,0); XCTAssertEqual(b.state.windows[0].frame.x,1240)
        XCTAssertEqual(report.results[0].outcome,.blocked)
    }
    func testUserMoveDuringUndoJournalPersistenceIsNotOverwritten() throws {
        let (b,r)=fixture(); let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        var calls=0
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:b,approved:true,persist:{_ in
            calls += 1; if calls==2 { b.state.windows[0].frame.x += 40 }
        })
        XCTAssertEqual(b.writes,1); XCTAssertEqual(undo.results[0].outcome,.blocked)
    }
    func testSubpixelUserMoveDuringPersistenceIsPreserved() throws {
        let (b,r)=fixture(); var calls=0
        _=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in
            calls += 1; if calls==2 { b.state.windows[0].frame.x += 0.5 }
        })
        XCTAssertEqual(b.writes,0); XCTAssertEqual(b.state.windows[0].frame.x,1200.5)
    }
    func testJournalWriteFailurePreventsWindowWrites() throws {
        let (b,r)=fixture()
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in throw LayoutError.unsupported})
        XCTAssertEqual(b.writes,0); XCTAssertEqual(report.results[0].outcome,.blocked)
    }
    func testAttemptMarkerMustBePersistedBeforeWrite() throws {
        let (b,r)=fixture(); var calls=0
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in calls += 1; if calls==2 { throw LayoutError.unsupported }})
        XCTAssertEqual(b.writes,0); XCTAssertEqual(report.results[0].outcome,.blocked)
    }
    func testNoApprovalDoesNotPersistOrWrite() throws {
        let (b,r)=fixture(); var persisted=0
        _=ManualRestorer.execute(try plan(b,r),windows:b,approved:false,persist:{_ in persisted += 1})
        XCTAssertEqual(b.writes,0); XCTAssertEqual(persisted,0)
    }
    func testChangedTopologyOrWindowTokenBlocksWrites() throws {
        let (b,r)=fixture(); let p=try plan(b,r)
        b.state.topology="changed"; _=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(b.writes,0)
        b.state.topology="stable"; b.state.windows[0].token="101:1"
        _=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in}); XCTAssertEqual(b.writes,0)
    }
    func testNewAmbiguousMatchAfterPreviewBlocksWrites() throws {
        let (b,r)=fixture(); let p=try plan(b,r)
        var duplicate=b.state.windows[0]; duplicate.token="100:2"; b.state.windows.append(duplicate)
        _=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in}); XCTAssertEqual(b.writes,0)
    }
    func testPartialWriteRollsBackAndReportsFailure() throws {
        let (b,r)=fixture(); let original=b.state.windows[0].frame
        b.failOnWrite=1
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed)
        XCTAssertEqual(report.journal?.entries[0].state,.rolledBack)
        XCTAssertEqual(b.state.windows[0].frame,original); XCTAssertEqual(b.writes,2)
    }
    func twoWindows() throws -> (MemoryWindows,MonitorLayoutRecord) {
        let (b,record)=fixture(); var r=record
        var second=b.state.windows[0]; second.token="100:2"; second.selector=WindowSelector(bundleID:"test.chat",title:"测试聊天")
        b.state.windows.append(second); r.profile.windows.append(SavedWindow(selector:second.selector,displayRole:.external,desktopLabel:"组甲",normalizedFrame:Rect(0.6,0.2,0.3,0.4)))
        return (b,r)
    }
    func testFailedLaterWindowIsUndoneAloneAndEarlierWindowStaysRestored() throws {
        let (b,r)=try twoWindows()
        let original=b.state.windows.map(\.frame); b.failOnWrite=2
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        let journal=try XCTUnwrap(report.journal)
        XCTAssertEqual(journal.entries.map(\.state),[.verified,.rolledBack])
        XCTAssertNotEqual(b.state.windows[0].frame,original[0]); XCTAssertEqual(b.state.windows[1].frame,original[1])
        XCTAssertEqual(report.failures,[RestoreFailure(bundleID:"test.chat",reason:.failed)])
    }
    func testFirstWindowFailingDoesNotStopTheRest() throws {
        // The 0.6.6 home case: the first window failed and every later window was skipped.
        let (b,r)=try twoWindows(); b.failOnWrite=1
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(try XCTUnwrap(report.journal).entries.map(\.state),[.rolledBack,.verified])
        XCTAssertEqual(report.results.map(\.outcome),[.failed,.verified])
    }
    func testSlowAppIsRetriedInsteadOfFailing() throws {
        let (b,r)=fixture(); let p=try plan(b,r)
        b.transientReads=2   // two "app did not answer" errors, then it answers
        let report=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.verified); XCTAssertTrue(report.failures.isEmpty)
    }
    func testAppThatNeverAnswersIsReportedAndOthersStillRun() throws {
        let (b,r)=try twoWindows(); let p=try plan(b,r)
        b.unresponsiveTokens=["100:1"]
        let report=ManualRestorer.execute(p,windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(report.results.map(\.outcome),[.blocked,.verified])
        XCTAssertEqual(report.failures,[RestoreFailure(bundleID:"test.editor",reason:.notResponding)])
        XCTAssertTrue(report.results[0].detail.contains("没有响应"))
    }
    func testDeferredAppRunsLast() throws {
        let (b,r)=try twoWindows(); var order=[String]()
        b.beforeWriteToken={ order.append($0) }
        _=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,deferredBundles:["test.editor"],persist:{_ in})
        XCTAssertEqual(order,["100:2","100:1"])
    }
    func testWindowThatNeverMovedIsReportedAsNotMoved() throws {
        let (b,r)=fixture(); b.noOp=true
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed)
        XCTAssertEqual(report.journal?.entries[0].state,.notMoved)
        XCTAssertTrue(report.results[0].detail.contains("未移动")); XCTAssertFalse(report.journal?.canUndo ?? true)
    }
    func testUnreadableWindowAfterFailedMoveThatNeverMovedIsNotMovedNotRollbackFailed() throws {
        // Write sent, readback shows the window unmoved, then the app stops answering during undo.
        let (b,r)=fixture(); b.noOp=true; let original=b.state.windows[0].frame
        var journal=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in}).journal!
        journal.entries[0].state = .rollbackFailed   // as recorded by 0.6.6
        b.unresponsiveTokens=["100:1"]
        let undo=ManualRestorer.undo(journal,windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(undo.journal?.entries[0].state,.notMoved); XCTAssertTrue(undo.results[0].detail.contains("未移动"))
        XCTAssertEqual(b.state.windows[0].frame,original)
    }
    func testUndoDoesNotOverwriteSubsequentUserMove() throws {
        let (b,r)=fixture()
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        b.state.windows[0].frame.x += 40
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results[0].outcome,.blocked); XCTAssertEqual(b.writes,1)
    }
    func testRollbackFailureIsVisibleAndRetryable() throws {
        let (b,r)=fixture(); b.failOnWrite=1; b.failRollback=true
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(report.journal?.entries[0].state,.rollbackFailed)
        XCTAssertTrue(report.results[0].detail.contains("回滚失败"))
        b.failRollback=false
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:b,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results[0].outcome,.verified)
    }
    func testSyntheticMonitorSavePreviewRestoreUndoUsesActualLocalStores() throws {
        let (b,r)=fixture(); let original=b.state.windows[0].frame
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file=dir.appendingPathComponent("monitor.json")
        try MonitorLayoutStore.save(r,to:file)
        let bytes=try Data(contentsOf:file); var revised=r; revised.savedAt=Date(timeIntervalSince1970:42)
        try MonitorLayoutStore.save(revised,to:file)
        XCTAssertEqual(try Data(contentsOf:VersionedStore.previousURL(for:file)),bytes)
        let loaded=try MonitorLayoutStore.load(from:file); XCTAssertEqual(loaded.profile,r.profile)
        var journalURL: URL?
        func persist(_ journal: RestoreJournal) throws {
            if let url=journalURL { try RestoreJournalStore.update(journal,at:url) }
            else { journalURL=try RestoreJournalStore.create(journal,in:dir.appendingPathComponent("transactions")) }
        }
        let report=ManualRestorer.execute(try plan(b,loaded),windows:b,approved:true,persist:persist)
        XCTAssertEqual(report.results[0].outcome,.verified)
        let stored=try RestoreJournalStore.load(from:try XCTUnwrap(journalURL))
        XCTAssertEqual(stored.entries[0].state,.verified)
        let undo=ManualRestorer.undo(stored,windows:b,approved:true,persist:persist)
        XCTAssertEqual(undo.results[0].outcome,.verified); XCTAssertEqual(b.state.windows[0].frame,original)
        XCTAssertEqual(try RestoreJournalStore.load(from:try XCTUnwrap(journalURL)).entries[0].state,.rolledBack)
    }
    func testBackupFailureLeavesCurrentLayoutBytesUnchanged() throws {
        let (_,r)=fixture(); let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file=dir.appendingPathComponent("monitor.json"); try MonitorLayoutStore.save(r,to:file)
        let bytes=try Data(contentsOf:file)
        try FileManager.default.createDirectory(at:VersionedStore.previousURL(for:file),withIntermediateDirectories:true)
        XCTAssertThrowsError(try MonitorLayoutStore.save(r,to:file))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testInvalidReplacementDoesNotAlterCurrentOrPreviousLayout() throws {
        let (_,r)=fixture(); let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let file=dir.appendingPathComponent("monitor.json"); try MonitorLayoutStore.save(r,to:file); try MonitorLayoutStore.save(r,to:file)
        let bytes=try Data(contentsOf:file); let backup=try Data(contentsOf:VersionedStore.previousURL(for:file))
        var invalid=r; invalid.profile.windows[0].normalizedFrame.width = -1
        XCTAssertThrowsError(try MonitorLayoutStore.save(invalid,to:file))
        XCTAssertEqual(try Data(contentsOf:file),bytes); XCTAssertEqual(try Data(contentsOf:VersionedStore.previousURL(for:file)),backup)
    }
    func testJournalUpdateCannotChangeRecordedBeforeState() throws {
        let (b,r)=fixture(); let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        var journal=try XCTUnwrap(report.journal); let url=try RestoreJournalStore.create(journal,in:dir)
        let before=try Data(contentsOf:url); journal.entries[0].before.frame.x += 1
        XCTAssertThrowsError(try RestoreJournalStore.update(journal,at:url)); XCTAssertEqual(try Data(contentsOf:url),before)
    }
    func testJournalRoundTripAndCreatesNewFileWithoutOverwriting() throws {
        let (b,r)=fixture()
        let report=ManualRestorer.execute(try plan(b,r),windows:b,approved:true,persist:{_ in})
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let journal=try XCTUnwrap(report.journal)
        let url=try RestoreJournalStore.create(journal,in:dir)
        let loaded=try RestoreJournalStore.load(from:url)
        XCTAssertEqual(loaded.id,journal.id); XCTAssertEqual(loaded.entries[0].before,journal.entries[0].before)
        XCTAssertThrowsError(try RestoreJournalStore.create(journal,in:dir))
        XCTAssertEqual(try RestoreJournalStore.load(from:url).entries[0].before,journal.entries[0].before)
    }
}

struct SlowAppError: TransientFailure { var isTransient: Bool { true } }
final class MemoryWindows: WindowBackend {
    var state: Snapshot; var writes=0; var noOp=false; var failOnWrite: Int?; var failRollback=false
    var beforeWrite: (() -> Void)?; var beforeWriteToken: ((String) -> Void)?
    /// Next N window reads fail as "app did not answer"; tokens in `unresponsiveTokens` never answer.
    var transientReads=0; var unresponsiveTokens=Set<String>()
    init(_ state: Snapshot) { self.state=state }
    func snapshot() throws -> Snapshot { state }
    func readWindow(token: String) throws -> ObservedWindow? {
        if unresponsiveTokens.contains(token) { throw SlowAppError() }
        if transientReads>0 { transientReads -= 1; throw SlowAppError() }
        return state.windows.first{$0.token==token}
    }
    func setFrame(window: ObservedWindow,to frame: Rect) throws {
        beforeWrite?(); beforeWriteToken?(window.token); writes += 1
        if failRollback && writes>1 { throw LayoutError.unsupported }
        guard let index=state.windows.firstIndex(where:{$0.token==window.token}) else { throw LayoutError.readbackUnavailable }
        if failOnWrite==writes { state.windows[index].frame.width=frame.width; throw LayoutError.unsupported }
        if !noOp { state.windows[index].frame=frame }
    }
}
