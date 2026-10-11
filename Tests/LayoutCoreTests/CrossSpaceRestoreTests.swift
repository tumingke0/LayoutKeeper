// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class CrossSpaceRestoreTests: XCTestCase {
    func fixture() throws -> (MemoryWindows,SpaceSimulation,RestorePlan) {
        let fixtures=ManualRestoreTests(); let (windows,record)=fixtures.fixture()
        let plan=try MonitorRestorePlanner.plan(record:record,monitor:fixtures.monitor,displayToken:"external",snapshot:windows.state,groupSpaces:["组甲":73],allowCrossSpace:true)
        return (windows,SpaceSimulation(windows),plan)
    }
    func testExplicitCrossSpaceOptInProducesReadyPlan() throws {
        let (_,_,plan)=try fixture(); XCTAssertEqual(plan.entries[0].status,.ready)
    }
    func testCrossSpaceMoveReadbackGeometryAndUndoComplete() throws {
        let (w,s,p)=try fixture(); let before=w.state.windows[0]
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.verified); XCTAssertEqual(s.moves,1); XCTAssertEqual(w.writes,1)
        let journal=try XCTUnwrap(report.journal)
        XCTAssertEqual(journal.entries[0].targetSpace,73); XCTAssertEqual(journal.entries[0].sourceDisplay,"external")
        XCTAssertEqual(journal.entries[0].before.spaceIDs,[72]); XCTAssertEqual(journal.entries[0].after?.spaceIDs,[73])
        let undo=ManualRestorer.undo(journal,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results[0].outcome,.verified); XCTAssertEqual(s.moves,2)
        XCTAssertEqual(w.state.windows[0].spaceIDs,before.spaceIDs); XCTAssertEqual(w.state.windows[0].frame,before.frame)
    }
    func testWithoutApprovedMoverNoCrossSpaceWrites() throws {
        let (w,s,p)=try fixture()
        let result=ManualRestorer.execute(p,windows:w,approved:true,persist:{_ in})
        XCTAssertEqual(result.results[0].outcome,.blocked); XCTAssertEqual(s.moves,0); XCTAssertEqual(w.writes,0)
    }
    func testDispatcherNoOpIsFailureAndDoesNotWriteGeometry() throws {
        let (w,s,p)=try fixture(); s.noOp=true
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed); XCTAssertEqual(w.writes,0)
        XCTAssertEqual(w.state.windows[0].spaceIDs,[72]); XCTAssertEqual(s.moves,1)
    }
    func testPartialDispatchFailureReturnsWindowToOriginalSpace() throws {
        let (w,s,p)=try fixture(); s.failAfterMove=1
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed); XCTAssertEqual(s.moves,2)
        XCTAssertEqual(w.state.windows[0].spaceIDs,[72]); XCTAssertEqual(w.writes,0)
        XCTAssertEqual(report.journal?.entries[0].state,.rolledBack)
    }
    func testGeometryFailureRollsBackSpaceAndOriginalFrame() throws {
        let (w,s,p)=try fixture(); let before=w.state.windows[0]; w.failOnWrite=1
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.journal?.entries[0].state,.rolledBack); XCTAssertEqual(s.moves,2)
        XCTAssertEqual(w.state.windows[0].frame,before.frame); XCTAssertEqual(w.state.windows[0].spaceIDs,before.spaceIDs)
    }
    func testTopologyChangesAfterDispatchStopGeometryAndRollback() throws {
        let (w,s,p)=try fixture(); s.afterMove={ w.state.topology="changed" }
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed); XCTAssertEqual(w.writes,0); XCTAssertEqual(s.moves,1)
        XCTAssertEqual(report.journal?.entries[0].state,.rollbackBlocked)
    }
    func testClosedWindowAfterDispatchStopsWithoutGuessingReplacement() throws {
        let (w,s,p)=try fixture(); s.afterMove={w.state.windows=[]}
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed); XCTAssertEqual(w.writes,0); XCTAssertEqual(s.moves,1)
        XCTAssertEqual(report.journal?.entries[0].state,.rollbackBlocked)
    }
    func testMultipleMembershipAfterDispatchCannotTriggerFrameOrReturnMove() throws {
        let (w,s,p)=try fixture(); s.afterMove={w.state.windows[0].spaceIDs=[72,73]}
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed); XCTAssertEqual(w.writes,0); XCTAssertEqual(s.moves,1)
    }
    func testMoveRollbackFailureIsVisibleAndExplicitUndoCanRetry() throws {
        let (w,s,p)=try fixture(); w.failOnWrite=1; s.failBeforeMove=2
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.journal?.entries[0].state,.rollbackFailed)
        XCTAssertTrue(report.results[0].detail.contains("回滚失败"))
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results[0].outcome,.verified); XCTAssertEqual(w.state.windows[0].spaceIDs,[72]); XCTAssertEqual(s.moves,3)
    }
    func testUndoDoesNotMoveUserAdjustedWindow() throws {
        let (w,s,p)=try fixture(); let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        w.state.windows[0].frame.x += 0.5
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results[0].outcome,.blocked); XCTAssertEqual(s.moves,1)
    }
    func testTargetSpaceRemovedDuringPersistenceBlocksDispatch() throws {
        let (w,s,p)=try fixture(); var calls=0
        _=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in calls += 1; if calls==2 {w.state.spaces.removeAll{$0.id==73}}})
        XCTAssertEqual(s.moves,0); XCTAssertEqual(w.writes,0)
    }
    func testWriteAheadAndAfterTransferReceiptsPrecedeGeometry() throws {
        let (w,s,p)=try fixture(); var saved=[RestoreJournal]()
        s.beforeMove={XCTAssertEqual(saved.last?.entries[0].state,.attempted)}
        w.beforeWrite={XCTAssertEqual(saved.last?.entries[0].after?.spaceIDs,[73])}
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{saved.append($0)})
        XCTAssertEqual(report.results[0].outcome,.verified)
    }
    func testWindowIdentityChangeAfterMoveStopsFurtherWrites() throws {
        let (w,s,p)=try fixture(); s.afterMove={w.state.windows[0].selector.document="file:///another"}
        let report=ManualRestorer.execute(p,windows:w,spaces:s,approved:true,persist:{_ in})
        XCTAssertEqual(report.results[0].outcome,.failed); XCTAssertEqual(w.writes,0); XCTAssertEqual(s.moves,1)
    }
}
final class SpaceSimulation: SpacesBackend {
    let windows: MemoryWindows; var canMove=true; var moves=0; var noOp=false
    var failBeforeMove: Int?; var failAfterMove: Int?; var beforeMove: (() -> Void)?; var afterMove: (() -> Void)?
    init(_ windows: MemoryWindows) { self.windows=windows }
    func move(window: ObservedWindow,to space: UInt64) throws {
        beforeMove?(); moves += 1
        if failBeforeMove==moves { throw LayoutError.unsupported }
        guard let index=windows.state.windows.firstIndex(where:{$0.token==window.token}) else { throw LayoutError.readbackUnavailable }
        if !noOp { windows.state.windows[index].spaceIDs=[space] }
        afterMove?()
        if failAfterMove==moves { throw LayoutError.unsupported }
    }
}
