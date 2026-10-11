// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class LayoutCoreTests: XCTestCase {
    let selector = WindowSelector(bundleID: "test.editor", title: "Project")
    var snapshot: Snapshot { Snapshot(session: UUID(), topology: "home", displays: [Display(token:"laptop",name:"Laptop",role:.builtIn,visible:Rect(0,30,1200,770)),Display(token:"new-monitor",name:"Monitor",role:.external,visible:Rect(1200,0,1600,1000))],spaces:[Space(id:901,displayToken:"laptop",active:true),Space(id:902,displayToken:"new-monitor",active:true),Space(id:903,displayToken:"new-monitor")],windows:[ObservedWindow(token:"temporary-42",selector:selector,frame:Rect(20,50,600,500),spaceIDs:[901])]) }
    var profile: Profile { Profile(location:"家",windows:[SavedWindow(selector:selector,displayRole:.external,desktopLabel:"开发",normalizedFrame:Rect(0.1,0.1,0.5,0.6))]) }
    func bindings(_ s: Snapshot, _ id: UInt64 = 903) -> [DesktopBinding] { [DesktopBinding(label:"开发",role:.external,spaceID:id,snapshot:s)] }
    func plan(_ s: Snapshot, move: Bool = true) throws -> RestorePlan { try Planner.plan(profile:profile,snapshot:s,bindings:bindings(s),canMoveSpaces:move) }
    func testLogicalRolesResolveNewMonitorAndRuntimeSpace() throws { let s=snapshot; let p=try plan(s); XCTAssertEqual(p.entries.count,1); XCTAssertEqual(p.entries.first?.targetDisplay,"new-monitor"); XCTAssertEqual(p.entries.first?.targetSpace,903); XCTAssertEqual(p.entries.first?.targetFrame,Rect(1360,100,800,600)) }
    func testAmbiguousWindowsAreBlocked() throws { var s=snapshot; var duplicate=s.windows[0]; duplicate.token="second"; s.windows.append(duplicate); XCTAssertEqual(try plan(s).entries.first?.status,.blocked) }
    func testFullScreenAndSplitAreSkipped() throws { var s=snapshot; s.windows[0].fullScreen=true; XCTAssertEqual(try plan(s).entries.first?.status,.skipped); s.windows[0].fullScreen=false; s.spaces[0].kind = .fullScreenOrSplit; XCTAssertEqual(try plan(s).entries.first?.status,.skipped) }
    func testMissingMonitorIsBlocked() throws { var s=snapshot; s.displays.removeLast(); XCTAssertEqual(try plan(s).entries.first?.status,.blocked) }
    func testCrossSpaceUnverifiedBackendBlocksBeforeGeometry() throws { let s=snapshot; XCTAssertEqual(try plan(s,move:false).entries.first?.status,.blocked) }
    func testStaleBindingIsBlocked() throws { let s=snapshot; let stale=bindings(snapshot); let p=try Planner.plan(profile:profile,snapshot:s,bindings:stale,canMoveSpaces:true); XCTAssertEqual(p.entries.first?.status,.blocked) }
    func testUnknownOrMultipleMembershipIsSkipped() throws { var s=snapshot; s.windows[0].spaceIDs=[]; XCTAssertEqual(try plan(s).entries.first?.status,.skipped); s.windows[0].spaceIDs=[901,902]; XCTAssertEqual(try plan(s).entries.first?.status,.skipped) }
    func testNoPersistentRuntimeIdentifiers() throws { let text=String(data:try JSONEncoder().encode(profile),encoding:.utf8)!; for key in ["spaceID","windowID","temporary-42","new-monitor","desktopNumber","901"] { XCTAssertFalse(text.contains(key),key) } }
    func testCaptureRequiresBindingsAndUniqueSelector() throws { let s=snapshot; let b=[DesktopBinding(label:"阅读",role:.builtIn,spaceID:901,snapshot:s)]; let (p,_)=try Planner.capture(location:"公司",snapshot:s,bindings:b); XCTAssertEqual(p.windows.count,1); XCTAssertEqual(p.windows.first?.desktopLabel,"阅读"); let (empty,issues)=try Planner.capture(location:"公司",snapshot:s,bindings:[]); XCTAssertTrue(empty.windows.isEmpty); XCTAssertEqual(issues.count,1) }
    func testFrameClampsToNegativeOriginMonitor() { XCTAssertEqual(Rect(-1,0.2,2,0.5).fitted(in:Rect(-1600,-200,1600,1000)),Rect(-1600,0,1600,500)) }
    func testInvalidProfileRejected() { var p=profile; p.windows[0].normalizedFrame.width = -1; XCTAssertThrowsError(try Planner.plan(profile:p,snapshot:snapshot,bindings:[],canMoveSpaces:true)) }
    func testSuccessfulReturnWithoutMoveFailsReadback() throws { let s=snapshot; let p=try plan(s); let b=Simulation(snapshot:s,spaceNoOp:true); let result=Restorer.execute(p,windows:b,spaces:b,approved:true); XCTAssertEqual(result.first?.outcome,.failed); XCTAssertEqual(b.geometryWrites,0) }
    func testSuccessfulGeometryReturnWithoutResizeFailsReadback() throws { var s=snapshot; s.windows[0].spaceIDs=[903]; let p=try plan(s); let b=Simulation(snapshot:s,geometryNoOp:true); XCTAssertEqual(Restorer.execute(p,windows:b,spaces:b,approved:true).first?.outcome,.failed) }
    func testSuccessfulReadbackIsVerified() throws { let s=snapshot; let b=Simulation(snapshot:s); XCTAssertEqual(Restorer.execute(try plan(s),windows:b,spaces:b,approved:true).first?.outcome,.verified) }
    func testNoApprovalWritesNothing() throws { let s=snapshot; let b=Simulation(snapshot:s); XCTAssertEqual(Restorer.execute(try plan(s),windows:b,spaces:b,approved:false).first?.outcome,.blocked); XCTAssertEqual(b.geometryWrites,0); XCTAssertEqual(b.spaceWrites,0) }
    func testTopologyChangeInvalidatesPreview() throws { let s=snapshot; let p=try plan(s); var changed=s; changed.topology="company"; let b=Simulation(snapshot:changed); XCTAssertEqual(Restorer.execute(p,windows:b,spaces:b,approved:true).first?.outcome,.blocked); XCTAssertEqual(b.spaceWrites,0) }
    func testReusedWindowTokenDoesNotMoveOtherDocument() throws { let s=snapshot; let p=try plan(s); var changed=s; changed.windows[0].selector.title="Different document"; let b=Simulation(snapshot:changed); XCTAssertEqual(Restorer.execute(p,windows:b,spaces:b,approved:true).first?.outcome,.blocked); XCTAssertEqual(b.spaceWrites,0) }
    func testSameSpaceGeometryWorksWithoutSpaceMover() throws { var s=snapshot; s.windows[0].spaceIDs=[903]; let p=try plan(s,move:false); XCTAssertEqual(p.entries.first?.status,.ready); let b=Simulation(snapshot:s); b.canMove=false; XCTAssertEqual(Restorer.execute(p,windows:b,spaces:b,approved:true).first?.outcome,.verified); XCTAssertEqual(b.spaceWrites,0) }
    func testDocumentIdentitySurvivesTitleChange() throws { var p=profile; p.windows[0].selector.document="file:///project.md"; var s=snapshot; s.windows[0].selector.document="file:///project.md"; s.windows[0].selector.title="Renamed tab"; XCTAssertEqual(try Planner.plan(profile:p,snapshot:s,bindings:bindings(s),canMoveSpaces:true).entries.first?.status,.ready) }
    func testDuplicateExternalRolesAreBlocked() throws { var s=snapshot; s.displays.append(Display(token:"third",name:"Third",role:.external,visible:Rect(2800,0,1000,800))); XCTAssertEqual(try plan(s).entries.first?.status,.blocked) }
    func testTwoRulesCannotClaimTheSameWindow() throws { var p=profile; p.windows.append(p.windows[0]); let s=snapshot; XCTAssertTrue(try Planner.plan(profile:p,snapshot:s,bindings:bindings(s),canMoveSpaces:true).entries.allSatisfy{$0.status == .blocked}) }
    func testProfileRoundTripRetainsLogicalLayoutOnly() throws { let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:dir) }; let file=dir.appendingPathComponent("home.json"); try ProfileStore.save(profile,to:file); XCTAssertEqual(try ProfileStore.load(from:file),profile) }
    func testSavingAgainRetainsExactPreviousVersion() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("home.json")
        try ProfileStore.save(profile,to:file)
        let original=try Data(contentsOf:file)
        var next=profile; next.windows[0].normalizedFrame.x=0.3
        try ProfileStore.save(next,to:file)
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("home.previous.json")),original)
        XCTAssertEqual(try ProfileStore.load(from:file),next)
    }
    func testUserMovesWindowAfterPreviewBlocksWrites() throws { let s=snapshot; let p=try plan(s); var changed=s; changed.windows[0].frame.x += 40; let b=Simulation(snapshot:changed); XCTAssertEqual(Restorer.execute(p,windows:b,spaces:b,approved:true).first?.outcome,.blocked); XCTAssertEqual(b.geometryWrites,0); XCTAssertEqual(b.spaceWrites,0) }
    func testMinimizedAndNonstandardAreSkipped() throws { var s=snapshot; s.windows[0].minimized=true; XCTAssertEqual(try plan(s).entries.first?.status,.skipped); s.windows[0].minimized=false; s.windows[0].ordinary=false; XCTAssertEqual(try plan(s).entries.first?.status,.skipped) }
}

final class Simulation: WindowBackend, SpacesBackend {
    var state: Snapshot; var spaceNoOp: Bool; var geometryNoOp: Bool; var geometryWrites=0; var spaceWrites=0; var canMove=true
    init(snapshot: Snapshot, spaceNoOp: Bool = false, geometryNoOp: Bool = false) { state=snapshot; self.spaceNoOp=spaceNoOp; self.geometryNoOp=geometryNoOp }
    func snapshot() throws -> Snapshot { state }
    func setFrame(window: ObservedWindow, to frame: Rect) throws { geometryWrites += 1; if !geometryNoOp, let i=state.windows.firstIndex(where:{$0.token==window.token}) { state.windows[i].frame=frame } }
    func readWindow(token: String) throws -> ObservedWindow? { state.windows.first{$0.token==token} }
    func move(window: ObservedWindow, to space: UInt64) throws { spaceWrites += 1; if !spaceNoOp, let i=state.windows.firstIndex(where:{$0.token==window.token}) { state.windows[i].spaceIDs=[space] } }
}
