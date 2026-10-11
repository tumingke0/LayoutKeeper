// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class SelfTestTests: XCTestCase {
    let ext="EXT"
    let visible=Rect(-204,-1050,1920,1050)
    let monitor=MonitorIdentity(vendor:1,model:2,serial:3,name:"DELL")
    func w(_ token:String,_ bundle:String,_ space:UInt64,_ title:String,started:Date?=Date(timeIntervalSince1970:100),frame:Rect?=nil) -> ObservedWindow {
        ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title),frame:frame ?? Rect(-204,-1050,1920,1050),spaceIDs:[space],processStartedAt:started)
    }
    func snapshot(_ windows:[ObservedWindow],active:UInt64=118) -> Snapshot {
        let spaces=[118,115,119,120].map{Space(id:UInt64($0),displayToken:ext,kind:.ordinary,active:UInt64($0)==active)}+[Space(id:4,displayToken:"BUILTIN",kind:.ordinary,active:true)]
        return Snapshot(session:UUID(),topology:"t",displays:[Display(token:ext,name:"DELL",role:.external,visible:visible),Display(token:"BUILTIN",name:"Built-in",role:.builtIn,visible:Rect(0,0,1512,949))],spaces:spaces,windows:windows)
    }
    func userWindows() -> [ObservedWindow] {
        [w("2:1063","com.example.ide",118,"IDE"),w("1:729","com.google.Chrome",115,"B"),w("1:2515","com.google.Chrome",119,"A"),w("1:827","com.google.Chrome",120,"C"),
         w("3:9","com.example.notes",4,"builtin",frame:Rect(0,0,800,600))]
    }
    func record(_ s:Snapshot) throws -> MonitorLayoutRecord { try ExternalLayoutCapture.capture(monitor:monitor,displayToken:ext,snapshot:s).0 }

    func testSelectionPrefersNonChromeOnActiveAndChromeOnHiddenSpaces() throws {
        let s=snapshot(userWindows()); let r=try record(s)
        let sel=SelfTestPlanner.select(record:r,snapshot:s,displayToken:ext,crossSpaceAvailable:true)
        XCTAssertEqual(sel.sameSpace?.token,"2:1063")
        let cross=try XCTUnwrap(sel.crossSpace)
        XCTAssertEqual(cross.window.selector.bundleID,"com.google.Chrome")
        XCTAssertNotEqual(cross.source,118);XCTAssertNotEqual(cross.target,118,"target should be a Space that is not shown")
        XCTAssertNotEqual(cross.source,cross.target)
        XCTAssertTrue([115,119,120].contains(cross.target))
    }
    func testBuiltInWindowsAreNeverSelected() throws {
        let s=snapshot(userWindows()); let r=try record(s)
        XCTAssertFalse(SelfTestPlanner.eligibleWindows(record:r,snapshot:s,displayToken:ext).contains{$0.token=="3:9"})
    }
    func testBuildGateSkipsCrossSpaceWithExactReason() throws {
        let s=snapshot(userWindows()); let r=try record(s)
        let sel=SelfTestPlanner.select(record:r,snapshot:s,displayToken:ext,crossSpaceAvailable:false,crossSpaceUnavailableReason:"SPControlledBuildIsSupported=0")
        XCTAssertNil(sel.crossSpace);XCTAssertEqual(sel.crossSpaceSkip,"SPControlledBuildIsSupported=0");XCTAssertNotNil(sel.sameSpace)
    }
    func testCrossSpaceNeedsLaunchTimeAndAmbiguousTitlesAreExcluded() throws {
        var windows=userWindows()
        windows[1].processStartedAt=nil;windows[2].processStartedAt=nil;windows[3].processStartedAt=nil
        let s=snapshot(windows); let r=try record(s)
        let sel=SelfTestPlanner.select(record:r,snapshot:s,displayToken:ext,crossSpaceAvailable:true)
        XCTAssertNil(sel.crossSpace,"only the same-Space window has a launch time and it is reserved for step B")
        let dup=snapshot([w("2:1","com.example.ide",118,"SAME"),w("2:2","com.example.ide",115,"SAME")])
        let dupRecord=MonitorLayoutRecord(monitor:monitor,profile:Profile(location:"x",windows:[SavedWindow(selector:WindowSelector(bundleID:"com.example.ide",title:"SAME"),displayRole:.external,desktopLabel:"g",normalizedFrame:Rect(0,0,1,1))]))
        XCTAssertTrue(SelfTestPlanner.eligibleWindows(record:dupRecord,snapshot:dup,displayToken:ext).isEmpty)
    }
    func testGroupSpacesFollowCurrentSlotsAndPlanRestrictionTouchesOnlyOneWindow() throws {
        let s=snapshot(userWindows()); let r=try record(s)
        let bindings=SelfTestPlanner.groupSpaces(record:r,snapshot:s,displayToken:ext)
        XCTAssertEqual(Set(bindings.values),[118,115,119,120]);XCTAssertEqual(bindings.count,4)
        let plan=try MonitorRestorePlanner.plan(record:r,monitor:monitor,displayToken:ext,snapshot:s,groupSpaces:bindings)
        XCTAssertEqual(plan.entries.filter{$0.status == .ready}.count,4)
        let restricted=SelfTestPlanner.restrict(plan,toToken:"1:2515")
        XCTAssertEqual(restricted.entries.filter{$0.status == .ready}.map{$0.window?.token},["1:2515"])
        XCTAssertTrue(restricted.entries.filter{$0.window?.token != "1:2515"}.allSatisfy{$0.status == .skipped})
    }
    func testGroupSpacesRefusesConflicts() throws {
        let s=snapshot(userWindows()); let r=try record(s)
        var moved=s;moved.windows[2].spaceIDs=[115]  // Chrome "A" now shares Space 115 with "B"
        let bindings=SelfTestPlanner.groupSpaces(record:r,snapshot:moved,displayToken:ext)
        XCTAssertFalse(bindings.values.contains(115),"two groups on one Space are not bound")
        XCTAssertEqual(bindings.count,2)
    }
    func testNudgeStaysInsideVisibleFrameAndDiffers() {
        for frame in [visible,Rect(-204,-1050,800,600),Rect(1400,-400,300,200),Rect(-204,-1050,150,80)] {
            let n=SelfTestPlanner.nudged(frame,within:visible)
            XCTAssertFalse(n.near(frame),"\(frame)")
            XCTAssertGreaterThanOrEqual(n.x,visible.x);XCTAssertGreaterThanOrEqual(n.y,visible.y)
            XCTAssertLessThanOrEqual(n.x+n.width,visible.x+visible.width+0.001);XCTAssertLessThanOrEqual(n.y+n.height,visible.y+visible.height+0.001)
        }
        XCTAssertEqual(SelfTestPlanner.nudged(Rect(0,-900,800,600),within:visible),Rect(40,-860,680,510))
        XCTAssertEqual(SelfTestPlanner.nudged(visible,within:visible),Rect(-164,-1010,1800,960),"a maximized window must be able to move after shrinking")
    }
    func testReportRoundTripsAndContainsNoTitles() throws {
        var report=SelfTestReport();report.startedAt=Date(timeIntervalSince1970:1_791_000_000);report.appBuild="6";report.macOSBuild="26A428"
        let window=w("1:2515","com.google.Chrome",119,"SECRET TAB TITLE")
        var step=SelfTestStep(name:"C1");step.status = .pass;step.windows=[SelfTestWindowRef(window:window,slot:3)]
        step.readbacks=[SelfTestReadback(label:"移动后",observed:window,expectedFrame:window.frame,expectedSpace:119)]
        step.messages=["执行：verified · 目标普通桌面、位置和大小均已回读验证"]
        report.steps=[step];var failed=SelfTestStep(name:"C3");failed.status = .fail;report.steps.append(failed)
        let json=report.json()
        XCTAssertFalse(json.contains("SECRET"));XCTAssertFalse(report.text.contains("SECRET"))
        XCTAssertTrue(json.contains(SelfTestPlanner.titleHash("SECRET TAB TITLE")))
        XCTAssertEqual(SelfTestPlanner.titleHash("x").count,8)
        XCTAssertEqual(try SelfTestReport.decode(Data(json.utf8)),report)
        XCTAssertEqual(report.overall,.fail);XCTAssertTrue(step.readbacks[0].matches)
        XCTAssertTrue(report.text.contains("[pass] C1"));XCTAssertTrue(report.text.contains("1:2515"))
    }
    func testReadbackRequiresBothFrameAndSpace() {
        let window=w("1:1","b",119,"t")
        XCTAssertFalse(SelfTestReadback(label:"x",observed:window,expectedFrame:window.frame,expectedSpace:120).matches)
        XCTAssertFalse(SelfTestReadback(label:"x",observed:window,expectedFrame:Rect(0,0,10,10),expectedSpace:119).matches)
        XCTAssertFalse(SelfTestReadback(label:"x",observed:nil,expectedFrame:nil,expectedSpace:nil).matches)
    }
    func testOverallStatus() {
        var r=SelfTestReport();XCTAssertEqual(r.overall,.notRun)
        var skip=SelfTestStep(name:"a");skip.status = .skip;r.steps=[skip];XCTAssertEqual(r.overall,.skip)
        var pass=SelfTestStep(name:"b");pass.status = .pass;r.steps.append(pass);XCTAssertEqual(r.overall,.pass)
    }
}
