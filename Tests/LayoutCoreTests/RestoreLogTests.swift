// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class RestoreLogTests: XCTestCase {
    func testAppendRotatesAtSizeKeepingOneOldFile() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let log=RestoreLog(url:dir.appendingPathComponent("restore-log.txt"),maxBytes:200)
        for i in 1...12 { log.append("event \(i)\nsecond line") }
        let lines=log.read()
        XCTAssertFalse(lines.isEmpty); XCTAssertTrue(lines.last!.hasSuffix("event 12 second line"))
        XCTAssertEqual(log.oldURL.lastPathComponent,"restore-log.old.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath:log.oldURL.path))
        let size=(try FileManager.default.attributesOfItem(atPath:log.url.path)[.size] as! NSNumber).intValue
        XCTAssertLessThanOrEqual(size,200)
        let files=try FileManager.default.contentsOfDirectory(atPath:dir.path)
        XCTAssertEqual(Set(files),["restore-log.txt","restore-log.old.txt"])
        XCTAssertEqual(log.tail(1).count,1)
    }
    func testHashIsShortAndStable() {
        XCTAssertEqual(RestoreLog.hash("abc"),"ba7816"); XCTAssertEqual(RestoreLog.hash(""),"-"); XCTAssertEqual(RestoreLog.t("abc"),"t:ba7816")
    }
    func testDetailedLinesNeverContainRawTitlesOrURLs() {
        let title="私人标题 secret-page - Google Chrome - sam", url="https://private.example.com/inbox", other="另一个私密窗口"
        let ext="AAAA-EXT", bi="BBBB-BI"
        let displays=[Display(token:ext,name:"DELL U2720Q",role:.external,visible:Rect(0,0,2000,1000)),Display(token:bi,name:"Built-in",role:.builtIn,visible:Rect(2000,0,1500,900))]
        let spaces=[Space(id:11,displayToken:ext,active:true),Space(id:12,displayToken:ext),Space(id:21,displayToken:bi,active:true),Space(id:22,displayToken:bi,kind:.fullScreenOrSplit)]
        let w1=ObservedWindow(token:"100:5",selector:WindowSelector(bundleID:"com.google.Chrome",document:url,title:title),frame:Rect(2010,10,800,600),spaceIDs:[21])
        let w2=ObservedWindow(token:"200:7",selector:WindowSelector(bundleID:"app.other",title:other),frame:Rect(0,0,1000,1000),spaceIDs:[12])
        let s=Snapshot(session:UUID(),topology:"topo",displays:displays,spaces:spaces,windows:[w1,w2])
        var saved=SavedWindow(selector:WindowSelector(bundleID:"com.google.Chrome",document:url,title:title),displayRole:.external,desktopLabel:"1",normalizedFrame:Rect(0,0,0.5,0.5),desktopIndex:1)
        saved.browserProfile="Profile 1"
        let saved2=SavedWindow(selector:WindowSelector(bundleID:"app.other",title:other),displayRole:.external,desktopLabel:"2",normalizedFrame:Rect(0,0,0.5,1),desktopIndex:2)
        let record=MonitorLayoutRecord(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"DELL U2720Q"),savedAt:Date(),profile:Profile(location:"x",windows:[saved,saved2]))
        let plan=try! QuickRestorePlanner.plan(record:record,monitor:record.monitor,displayToken:ext,snapshot:s,allowCrossSpace:true,browserProfiles:["100:5":"Profile 1"])
        let journal=RestoreJournal(id:UUID(),createdAt:Date(),session:UUID(),topology:"t",entries:[RestoreJournalEntry(planIndex:0,before:w1,targetFrame:Rect(0,0,1000,500),targetDisplay:ext,targetSpace:11,sourceDisplay:bi,after:w1,state:.verified,detail:"ok")])
        let report=ManualRestoreReport(journal:journal,results:[],persistenceIssues:[],failures:[])
        let lines=RestoreLog.snapshotLines(s,label:"snap",includeWindows:true) +
            RestoreLog.planDetail(trigger:"auto",plan:plan,record:record,snapshot:s,displayToken:ext,browserProfiles:["100:5":"Profile 1"]) +
            RestoreLog.journalLines(trigger:"auto",report:report)
        let text=lines.joined(separator:"\n")
        for secret in ["私人标题","secret-page","private.example.com","inbox","另一个私密窗口"," - sam","AAAA-EXT","BBBB-BI"] { XCTAssertFalse(text.contains(secret),"leaked \(secret)\n\(text)") }
        XCTAssertTrue(text.contains(RestoreLog.t(title)),text)
        XCTAssertTrue(text.contains("plan-item auto #0 com.google.Chrome"),text)
        XCTAssertTrue(text.contains("cand 100:5"),text)
        XCTAssertTrue(text.contains("<= CHOSEN"),text)
        XCTAssertTrue(text.contains("auto="),text)
        XCTAssertTrue(text.contains("spaces=[1:11*,2:12]"),text)
        XCTAssertTrue(text.contains("fullScreenOrSplit:22"),text)
        XCTAssertTrue(text.contains("exec auto 100:5 com.google.Chrome"),text)
    }
    func testAutoReasonExplainsManualOnlyKinds() {
        var a=QuickRestoreItem(savedIndex:0,bundleID:"x",savedTitle:"",currentTitle:nil,currentSlot:nil,targetSlot:1,chosenToken:"1:1",candidates:[],matchKind:.onlyWindow,state:.ready,reason:"")
        a.crossDisplay=true
        XCTAssertEqual(RestoreLog.autoReason(a),"yes","another display is no reason to hold back")
        a.matchKind = .tieBreak; XCTAssertTrue(RestoreLog.autoReason(a).contains("not a confident"))
        a.matchKind = .elimination; XCTAssertTrue(RestoreLog.autoReason(a).contains("manual-only"))
        a.matchKind = .title; XCTAssertEqual(RestoreLog.autoReason(a),"yes")
        a.state = .needsConfirmation; XCTAssertEqual(RestoreLog.autoReason(a),"no(state=needsConfirmation)")
    }
    func testSummaryHasNoWindowTitles() {
        let w=ObservedWindow(token:"1:1",selector:WindowSelector(bundleID:"app.secret",title:"私人标题"),frame:Rect(0,0,100,100),spaceIDs:[1])
        let journal=RestoreJournal(id:UUID(),createdAt:Date(),session:UUID(),topology:"t",entries:[RestoreJournalEntry(planIndex:0,before:w,targetFrame:Rect(0,0,200,200),targetDisplay:"d",state:.notMoved,detail:"x")])
        let report=ManualRestoreReport(journal:journal,results:[RestoreResult(title:"私人标题",outcome:.failed,detail:"x")],persistenceIssues:[],failures:[RestoreFailure(bundleID:"app.secret",reason:.notResponding)])
        let line=RestoreLog.summary(trigger:"manual",report:report)
        XCTAssertFalse(line.contains("私人标题")); XCTAssertTrue(line.contains("notMoved=1")); XCTAssertTrue(line.contains("app.secret:notResponding"))
    }
    func testPlanSummaryListsStatesWithoutTitles() {
        var a=QuickRestoreItem(savedIndex:0,bundleID:"app.one",savedTitle:"私人标题",currentTitle:"私人标题",currentSlot:nil,targetSlot:1,chosenToken:"1:1",candidates:[],matchKind:.onlyWindow,state:.ready,reason:"")
        a.crossDisplay=true
        let b=QuickRestoreItem(savedIndex:1,bundleID:"app.two",savedTitle:"x",currentTitle:nil,currentSlot:nil,targetSlot:2,chosenToken:nil,candidates:[],matchKind:.none,state:.missing,reason:"")
        let plan=QuickRestorePlan(items:[a,b],plan:RestorePlan(session:UUID(),topology:"t",entries:[]),entrySavedIndex:[],desktopsNow:2,desktopsNeeded:3)
        let line=RestoreLog.planSummary(trigger:"auto",plan:plan)
        XCTAssertFalse(line.contains("私人标题"))
        XCTAssertTrue(line.contains("app.one:ready/onlyWindow/crossDisplay/auto"),line)
        XCTAssertTrue(line.contains("app.two:missing/none"),line)
        XCTAssertTrue(line.contains("desktops=2/3"),line)
    }
}
