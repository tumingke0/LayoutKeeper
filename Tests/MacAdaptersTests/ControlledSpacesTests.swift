// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import MacAdapters
import LayoutCore

final class ControlledSpacesTests: XCTestCase {
    func fixture() throws -> (ObservedWindow,Snapshot,SpaceMovePermit,WindowOwnershipClaim) {
        let w=ObservedWindow(token:"44:9",selector:WindowSelector(bundleID:"test.app",document:"file:///test",title:"测试"),frame:Rect(0,0,500,400),spaceIDs:[1],processStartedAt:Date(timeIntervalSince1970:10))
        let s=Snapshot(session:UUID(),topology:"frozen",displays:[Display(token:"a",name:"源",role:.builtIn,visible:Rect(0,0,1000,800)),Display(token:"b",name:"目标",role:.external,visible:Rect(1000,0,1200,900))],spaces:[Space(id:1,displayToken:"a"),Space(id:2,displayToken:"b"),Space(id:3,displayToken:"b")],windows:[w])
        let p=try SpaceMovePermit(window:w,targetSpace:2,targetDisplay:"b",snapshot:s)
        let c=WindowOwnershipClaim(token:w.token,axPID:44,cgPID:44,windowID:9,processStartedAt:w.processStartedAt!,bundleID:w.selector.bundleID)
        return (w,s,p,c)
    }
    func testMatchingAXCGAndProcessIdentityResolveOnlyApprovedTransition() throws {
        let (w,s,p,c)=try fixture(); let move=try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c)
        XCTAssertEqual(move.source,1);XCTAssertEqual(move.target,2);XCTAssertEqual(move.targetDisplay,"b")
    }
    func testReverseTransitionIsAllowedForRollbackWithSameIdentity() throws {
        let (window,snapshot,p,c)=try fixture();var w=window;var s=snapshot;w.spaceIDs=[2];w.frame=Rect(1100,20,400,400);s.windows=[w]
        let move=try ControlledSpaceGate.resolve(window:w,to:1,permit:p,snapshot:s,claim:c)
        XCTAssertEqual(move.source,2);XCTAssertEqual(move.targetDisplay,"a")
    }
    func testCGOrAXOwnerMismatchIsRejected() throws {
        let (w,s,p,claim)=try fixture();var c=claim;c.cgPID=45
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
        c=claim;c.axPID=45;XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
    }
    func testProcessRestartOrWindowIDMismatchIsRejected() throws {
        let (w,s,p,claim)=try fixture();var c=claim;c.processStartedAt=Date(timeIntervalSince1970:11)
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
        c=claim;c.windowID=10;XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
    }
    func testUnapprovedDesktopIsRejected() throws {
        let (w,s,p,c)=try fixture();XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:3,permit:p,snapshot:s,claim:c))
    }
    func testSessionOrTopologyChangeIsRejected() throws {
        let (w,snapshot,p,c)=try fixture();var s=snapshot;s.session=UUID()
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
        s=snapshot;s.topology="changed";XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
    }
    func testTargetDisplayOrSpaceKindChangeIsRejected() throws {
        let (w,snapshot,p,c)=try fixture();var s=snapshot;s.spaces[1].displayToken="a"
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
        s=snapshot;s.spaces[1].kind = .fullScreenOrSplit;XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
    }
    func testAmbiguousWindowAndMultipleMembershipAreRejected() throws {
        let (window,snapshot,p,c)=try fixture();var s=snapshot;var duplicate=window;duplicate.token="44:10";s.windows.append(duplicate)
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:window,to:2,permit:p,snapshot:s,claim:c))
        var w=window;w.spaceIDs=[1,2];s=snapshot;s.windows=[w]
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
    }
    func testUserMoveAfterCallerReadIsRejected() throws {
        let (w,snapshot,p,c)=try fixture();var s=snapshot;s.windows[0].frame.x += 0.5
        XCTAssertThrowsError(try ControlledSpaceGate.resolve(window:w,to:2,permit:p,snapshot:s,claim:c))
    }
    func testMissingProcessStartCannotCreatePermit() throws {
        let (window,s,_,_)=try fixture();var w=window;w.processStartedAt=nil
        XCTAssertThrowsError(try SpaceMovePermit(window:w,targetSpace:2,targetDisplay:"b",snapshot:s))
    }
}
