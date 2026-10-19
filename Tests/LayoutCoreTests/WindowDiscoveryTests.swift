// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class WindowDiscoveryTests: XCTestCase {
    // Trait words as observed read-only on macOS 27.0 (26A428).
    let documentWindow=WindowServerTraits(parentID:0,attributes:0x2,tags:0x300000100082401)
    let chromePopup=WindowServerTraits(parentID:0,attributes:0,tags:0x1400c0402)
    let closedWindow=WindowServerTraits(parentID:0,attributes:0,tags:0x300000100080401)
    func row(_ id:UInt32,pid:Int32=10,layer:Int=0,size:(Double,Double)=(1920,1050),alpha:Double=1,spaces:[UInt64]?=[115],traits:WindowServerTraits?) -> CGWindowCandidate {
        CGWindowCandidate(windowID:id,ownerPID:pid,layer:layer,bounds:Rect(0,0,size.0,size.1),alpha:alpha,spaceIDs:spaces,traits:traits)
    }
    func testDocumentWindowsAreCandidatesAndHelpersAreNot() {
        XCTAssertNil(WindowCandidateRules.exclusion(row(1,traits:documentWindow)))
        XCTAssertEqual(WindowCandidateRules.exclusion(row(2,size:(1506,458),traits:chromePopup)),.notDocumentWindow)
        XCTAssertEqual(WindowCandidateRules.exclusion(row(3,spaces:[4],traits:closedWindow)),.orderedOut)
        var minimized=closedWindow;minimized.tags |= UInt64(1)<<60
        XCTAssertNil(WindowCandidateRules.exclusion(row(4,traits:minimized)),"minimized windows stay candidates; saving skips them later")
    }
    func testGeometryLayerParentAndMembershipRules() {
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,layer:3,traits:documentWindow)),.nonzeroLayer)
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,traits:WindowServerTraits(parentID:9,attributes:2,tags:1))),.attachedToParent)
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,size:(99,500),traits:documentWindow)),.undersized)
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,size:(500,49),traits:documentWindow)),.undersized)
        XCTAssertNil(WindowCandidateRules.exclusion(row(1,size:(100,50),traits:documentWindow)))
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,alpha:0,traits:documentWindow)),.transparent)
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,spaces:[],traits:documentWindow)),.noSpaceMembership)
        XCTAssertEqual(WindowCandidateRules.exclusion(row(1,spaces:nil,traits:documentWindow)),.membershipUnreadable)
    }
    func testMissingTraitsFailSafeToCandidate() {
        XCTAssertNil(WindowCandidateRules.exclusion(row(1,size:(1506,458),traits:nil)))
    }
    func testWantedSetIsCandidatesOfThatProcessMinusResolved() {
        let rows=[row(2515,traits:documentWindow),row(729,traits:documentWindow),row(827,traits:documentWindow),
                  row(10471,size:(403,84),traits:chromePopup),row(5,pid:11,traits:documentWindow),row(6,layer:25,traits:documentWindow),
                  row(7,spaces:[],traits:documentWindow)]
        XCTAssertEqual(WindowCandidateRules.wantedWindowIDs(pid:10,candidates:rows,resolved:[]),[2515,729,827])
        XCTAssertEqual(WindowCandidateRules.wantedWindowIDs(pid:10,candidates:rows,resolved:[2515]),[729,827])
        XCTAssertEqual(WindowCandidateRules.wantedWindowIDs(pid:10,candidates:rows,resolved:[2515,729,827]),[])
        XCTAssertEqual(WindowCandidateRules.wantedWindowIDs(pid:99,candidates:rows,resolved:[]),[])
    }
    func testDedupKeepsFirstSourceAndCountsMissingIDs() {
        let items:[(id:UInt32?,value:String)]=[(1,"windowsList"),(2,"windowsList"),(1,"focusedWindow"),(nil,"broken"),(0,"finderDesktop"),(3,"mainWindow"),(2,"mainWindow")]
        let result=WindowCandidateRules.uniqueByWindowID(items)
        XCTAssertEqual(result.unique.map(\.id),[1,2,3])
        XCTAssertEqual(result.unique.map(\.value),["windowsList","windowsList","mainWindow"])
        XCTAssertEqual(result.missingID,2);XCTAssertEqual(result.duplicates,2)
    }
    func testElementSweepResumesAndWrapsWithoutRepeats() {
        XCTAssertEqual(Array(ElementIDSweep(start:0,cap:4)),[0,1,2,3])
        XCTAssertEqual(Array(ElementIDSweep(start:2,cap:5)),[2,3,4,0,1])
        XCTAssertEqual(Array(ElementIDSweep(start:12,cap:5)),[2,3,4,0,1])
        XCTAssertEqual(Array(ElementIDSweep(start:3,cap:0)),[])
        XCTAssertEqual(Set(ElementIDSweep(start:777,cap:1000)).count,1000)
    }
    func testUnresolvedRemoteWindowsMakeReportPartialAndAreUnknownNotGone() throws {
        var report=CapturePipelineReport();report.spaces=(1...4).map{CaptureSpaceCounts(index:$0,active:$0==1)}
        report.increment(.remoteTokenWanted,bundleID:"com.google.Chrome",by:3)
        report.increment(.remoteTokenResolved,bundleID:"com.google.Chrome",by:2)
        report.exclude(.remoteTokenUnresolved,bundleID:"com.google.Chrome")
        report.assessmentCompleted=true;report.finish()
        XCTAssertEqual(report.completeness,.partial)
        XCTAssertTrue(report.summary.contains("状态未知"));XCTAssertTrue(report.summary.contains("不代表已关闭"))
        XCTAssertNoThrow(try report.validate(capturedCount:0))
        let decoded=try JSONDecoder().decode(CapturePipelineReport.self,from:JSONEncoder().encode(report))
        XCTAssertEqual(decoded,report)
    }
    func testOffSpaceWindowsFoundByRemoteLookupAreCapturedPerSlotAndTraceDecisionsStayOutOfRecord() throws {
        let display=Display(token:"ext",name:"External",role:.external,visible:Rect(-204,-1050,1920,1050))
        let spaces=[90_000_118,90_000_115,90_000_119,90_000_120].enumerated().map{Space(id:UInt64($0.element),displayToken:"ext",kind:.ordinary,active:$0.offset==0)}
        func w(_ token:String,_ bundle:String,_ space:UInt64,_ title:String) -> ObservedWindow {
            ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title),frame:Rect(-204,-1050,1920,1050),spaceIDs:[space],ordinary:true,minimized:false,fullScreen:false)
        }
        let snap=Snapshot(session:UUID(),topology:"t",displays:[display],spaces:spaces,windows:[w("1:8802515","com.google.Chrome",90_000_119,"A"),w("1:729","com.google.Chrome",90_000_115,"B"),w("1:827","com.google.Chrome",90_000_120,"C"),w("2:8801063","com.example.ide",90_000_118,"D")])
        let result=try ExternalLayoutCapture.assess(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"DELL"),displayToken:"ext",snapshot:snap)
        XCTAssertEqual(result.record.profile.windows.count,4)
        XCTAssertEqual(result.decisions,["1:8802515":"captured","1:729":"captured","1:827":"captured","2:8801063":"captured"])
        XCTAssertEqual(result.record.captureReport?.spaces.map(\.captured),[1,1,1,1])
        XCTAssertEqual(result.record.captureReport?.count(.captured,bundleID:"com.google.Chrome"),3)
        let json=String(data:try JSONEncoder().encode(result.record),encoding:.utf8)!
        for leaked in ["8802515","8801063","1:729","1:827"] {XCTAssertFalse(json.contains(leaked),"layout record must not contain window tokens: \(leaked)")}
        // Desk identity is kept on purpose since 0.6.9 (stable across unplug/replug).
        XCTAssertEqual(Set(result.record.profile.windows.compactMap(\.desktopID)),[90_000_118,90_000_115,90_000_119,90_000_120])
    }
    func testTraceLineIsReadable() {
        let entry=CaptureTraceEntry(bundleID:"com.google.Chrome",windowID:10471,width:403,height:84,spaceSlot:2,placement:"selectedDisplay",exclusion:.notDocumentWindow,axSource:nil,outcome:"notCandidate")
        XCTAssertTrue(entry.line.contains("弹出/辅助窗口"));XCTAssertTrue(entry.line.contains("桌面2"))
    }
}
