// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class CaptureReportTests: XCTestCase {
    let ide="com.example.ide",chrome="com.google.Chrome"
    let monitor=MonitorIdentity(vendor:1,model:2,serial:3,name:"Synthetic external")
    func snapshot(_ windows:[ObservedWindow]) -> Snapshot {
        Snapshot(session:UUID(),topology:"synthetic",displays:[Display(token:"ext",name:"External",role:.external,visible:Rect(0,0,1000,1000)),Display(token:"built",name:"Built-in",role:.builtIn,visible:Rect(1000,0,1000,1000))],spaces:(1...5).map{Space(id:UInt64($0),displayToken:"ext",kind:.ordinary,active:$0==3)}+[Space(id:6,displayToken:"built",kind:.ordinary,active:true)],windows:windows)
    }
    func window(_ token:String,_ bundle:String,_ spaces:[UInt64],title:String?=nil,ordinary:Bool=true,minimized:Bool=false,fullScreen:Bool=false) -> ObservedWindow {
        ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title ?? "PRIVATE-TITLE-\(token)"),frame:Rect(0,0,200,200),spaceIDs:spaces,ordinary:ordinary,minimized:minimized,fullScreen:fullScreen)
    }
    func testChromeCandidatesAcrossSpacesNeverBecomeSavedOrComplete() throws {
        var report=CapturePipelineReport();report.spaces=(1...5).map{CaptureSpaceCounts(index:$0,active:$0==3)}
        report.increment(.axEnumerated,bundleID:ide,by:2)
        for _ in 0..<2 {report.noteCGCandidate(bundleID:ide,selectedOrdinarySpaceIndex:3,seenInAX:true)}
        for slot in [3,3,3,4,4,4,4,5,5] {report.noteCGCandidate(bundleID:chrome,selectedOrdinarySpaceIndex:slot,seenInAX:false)}
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("ide-1",ide,[3]),window("ide-2",ide,[3])]),report:report)
        let result=try XCTUnwrap(record.captureReport)
        XCTAssertEqual(record.profile.windows.count,2)
        XCTAssertEqual(result.count(.captured,bundleID:chrome),0)
        XCTAssertEqual(result.count(.cgSelectedNotInAX,bundleID:chrome),9)
        XCTAssertEqual(result.spaces.filter{$0.cgCandidates>0}.count,3)
        XCTAssertEqual(result.spaces.filter{$0.captured>0}.count,1)
        XCTAssertEqual(record.completeness,.partial)
        XCTAssertTrue(record.captureSummary.contains("1/5"))
        XCTAssertTrue(record.captureSummary.contains("不完整"))
    }
    func testEveryMembershipAndEligibilityExclusionIsCounted() throws {
        let windows=[window("ok",ide,[3]),window("empty",chrome,[]),window("multi",chrome,[3,4]),window("unknown",chrome,[999]),window("other",chrome,[6]),window("role",chrome,[3],ordinary:false),window("mini",chrome,[3],minimized:true),window("full",chrome,[3],fullScreen:true),window("duplicate1",chrome,[3],title:"PRIVATE-DUPLICATE"),window("duplicate2",chrome,[4],title:"PRIVATE-DUPLICATE")]
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot(windows))
        let report=try XCTUnwrap(record.captureReport)
        XCTAssertEqual(report.count(.axReadable),10)
        for reason in [CaptureReason.emptyMembership,.multipleSpaces,.unknownSpace,.otherDisplay,.notOrdinary,.minimized,.fullscreen] {XCTAssertEqual(report.reason(reason,bundleID:chrome),1)}
        XCTAssertEqual(report.reason(.ambiguousSelector,bundleID:chrome),2)
        XCTAssertEqual(report.count(.captured),1)
    }
    func testCurrentAndOffSpaceReadableChromeWindowsCanBothBeCaptured() throws {
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("current",chrome,[3]),window("offspace",chrome,[4])]))
        XCTAssertEqual(record.profile.windows.count,2)
        XCTAssertEqual(record.captureReport?.spaces.filter{$0.captured>0}.count,2)
        XCTAssertEqual(record.completeness,.unverified)
    }
    func testUnknownRoleOrMembershipNeverBecomesSaved() throws {
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("unknown-role",chrome,[3],ordinary:false),window("unknown-space",chrome,[999])]))
        XCTAssertTrue(record.profile.windows.isEmpty);XCTAssertEqual(record.captureReport?.count(.captured),0)
    }
    func testReportContainsNoTitlesDocumentsTokensOrRuntimeIDs() throws {
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("PRIVATE-TOKEN",chrome,[3],title:"PRIVATE-TITLE")]))
        let report=try XCTUnwrap(record.captureReport);let bytes=try JSONEncoder().encode(report)
        let string=String(decoding:bytes,as:UTF8.self)
        for forbidden in ["PRIVATE-TITLE","PRIVATE-TOKEN","\"title\"","\"document\"","\"token\"","\"windowID\"","\"spaceID\""] {XCTAssertFalse(string.contains(forbidden))}
        XCTAssertTrue(string.contains(chrome))
    }
    func testPartialReportRetainsWarningAfterSaveAndLoad() throws {
        var report=CapturePipelineReport();report.spaces=(1...5).map{CaptureSpaceCounts(index:$0,active:$0==3)}
        report.noteCGCandidate(bundleID:chrome,selectedOrdinarySpaceIndex:4,seenInAX:false)
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("ok",ide,[3])]),report:report)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let file=dir.appendingPathComponent("record.json");try MonitorLayoutStore.save(record,to:file)
        let loaded=try MonitorLayoutStore.load(from:file)
        XCTAssertEqual(loaded.captureReport,record.captureReport);XCTAssertEqual(loaded.completeness,.partial)
        XCTAssertTrue(loaded.captureSummary.contains("不完整"))
    }
    func testLegacyRecordLoadsWithUnknownCompleteness() throws {
        let legacy=MonitorLayoutRecord(monitor:monitor,profile:Profile(location:"external",windows:[]))
        let decoded=try JSONDecoder().decode(MonitorLayoutRecord.self,from:JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.captureReport);XCTAssertNil(decoded.completeness)
        XCTAssertTrue(decoded.captureSummary.contains("未确认"))
    }
    func testMissingMismatchedOrAmbiguousCGOwnersAreNotConfirmed() {
        var report=CapturePipelineReport()
        XCTAssertTrue(report.noteWindowID(bundleID:chrome,axPID:10,cgOwners:[10]))
        XCTAssertFalse(report.noteWindowID(bundleID:chrome,axPID:10,cgOwners:[]))
        XCTAssertFalse(report.noteWindowID(bundleID:chrome,axPID:10,cgOwners:[20]))
        XCTAssertFalse(report.noteWindowID(bundleID:chrome,axPID:10,cgOwners:[10,20]))
        XCTAssertEqual(report.count(.windowIDResolved),4);XCTAssertEqual(report.count(.cgOwnerMatched),1)
        XCTAssertEqual(report.reason(.cgWindowMissing),1);XCTAssertEqual(report.reason(.cgOwnerMismatch),2)
        XCTAssertEqual(report.count(.captured),0)
    }
    func testRepeatedAssessmentDoesNotDoubleCountCapturedOrRejectedWindows() throws {
        let state=snapshot([window("ok",ide,[3]),window("unknown",chrome,[])])
        let (first,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:state)
        let report=try ExternalLayoutCapture.inspect(monitor:monitor,displayToken:"ext",snapshot:state,report:first.captureReport)
        XCTAssertEqual(report.count(.captured),1);XCTAssertEqual(report.reason(.emptyMembership),1)
        XCTAssertEqual(report.spaces.reduce(0){$0+$1.captured},1)
    }
    func testReadOnlyInspectionPreservesExistingRecordBytes() throws {
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("saved",ide,[3])]))
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("record.json");try MonitorLayoutStore.save(record,to:url)
        let before=try Data(contentsOf:url)
        let report=try ExternalLayoutCapture.inspect(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("check-other",chrome,[4]),window("check-unknown",chrome,[])]))
        XCTAssertEqual(report.count(.captured),1);XCTAssertEqual(report.reason(.emptyMembership),1)
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:VersionedStore.previousURL(for:url).path))
    }
    func testFailedAssessmentCannotClaimZeroSaveableWindows() {
        var report=CapturePipelineReport();report.globalReasons["snapshotUnavailable"]=1;report.finish()
        XCTAssertFalse(report.assessmentCompleted);XCTAssertTrue(report.summary.contains("数量未知"))
        XCTAssertFalse(report.summary.contains("可保存 0"))
    }
    func testInspectionBudgetExhaustionKeepsTotalUnknown() {
        var report=CapturePipelineReport();report.assessmentCompleted=true;report.globalReasons["inspectionBudgetExceeded"]=1;report.finish()
        XCTAssertEqual(report.completeness,.partial)
        XCTAssertTrue(report.summary.contains("总量未知"));XCTAssertTrue(report.summary.contains("读取时限"))
    }
    func testUnrepresentableFrameIsAnExclusionNotWholeCaptureFailure() throws {
        var huge=window("huge",chrome,[3]);huge.frame=Rect(0,0,5000,5000)
        let (record,_)=try ExternalLayoutCapture.capture(monitor:monitor,displayToken:"ext",snapshot:snapshot([window("ok",ide,[3]),huge]))
        XCTAssertEqual(record.profile.windows.count,1)
        XCTAssertEqual(record.captureReport?.reason(.invalidFrame,bundleID:chrome),1)
    }
    func testSuccessfulEmptyAXValueIsNotReportedAsPermissionOrAnAXError() {
        var report=CapturePipelineReport();report.emptyAXValue(operation:"AXWindows",bundleID:chrome);report.finish()
        XCTAssertEqual(report.reason(.axEmptyValue),1);XCTAssertTrue(report.applications[0].axErrors.isEmpty)
        XCTAssertEqual(report.applications[0].emptyAXValues["AXWindows"],1);XCTAssertEqual(report.completeness,.partial)
    }
}
