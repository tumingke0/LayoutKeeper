// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class QuickRestoreTests: XCTestCase {
    let monitor=MonitorIdentity(vendor:1,model:2,serial:3,name:"DELL SE2416H")
    let visible=Rect(1200,0,1600,1000)
    func snapshot(_ windows: [ObservedWindow], spaces: [Space]? = nil) -> Snapshot {
        Snapshot(session:UUID(),topology:"t",displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,0,1200,800)),Display(token:"ext",name:"DELL",role:.external,visible:visible)],
                 spaces:spaces ?? [Space(id:10,displayToken:"builtin",active:true),Space(id:201,displayToken:"ext",active:true),Space(id:290,displayToken:"ext",kind:.fullScreenOrSplit),Space(id:202,displayToken:"ext"),Space(id:203,displayToken:"ext")],windows:windows)
    }
    func w(_ token: String,_ bundle: String,_ title: String,doc: String? = nil,space: UInt64,_ frame: Rect = Rect(1300,100,800,600)) -> ObservedWindow {
        ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,document:doc,title:title),frame:frame,spaceIDs:[space],processStartedAt:Date(timeIntervalSince1970:1000))
    }
    func saved(_ bundle: String,_ title: String,doc: String? = nil,slot: Int?,_ frame: Rect = Rect(0.5,0.1,0.4,0.5)) -> SavedWindow {
        SavedWindow(selector:WindowSelector(bundleID:bundle,document:doc,title:title),displayRole:.external,desktopLabel:"组-\(slot ?? 0)",normalizedFrame:frame,desktopIndex:slot)
    }
    func record(_ windows: [SavedWindow]) -> MonitorLayoutRecord { MonitorLayoutRecord(monitor:monitor,profile:Profile(location:"DELL",windows:windows)) }
    func plan(_ r: MonitorLayoutRecord,_ s: Snapshot,choices: [Int:QuickChoice] = [:],cross: Bool = true) throws -> QuickRestorePlan {
        try QuickRestorePlanner.plan(record:r,monitor:monitor,displayToken:"ext",snapshot:s,choices:choices,allowCrossSpace:cross)
    }

    // MARK: bindings derivation
    func testNthSavedDesktopMapsToNthOrdinaryDesktopSkippingFullscreenSpaces() throws {
        let s=snapshot([w("1:1","app.a","A",space:201),w("1:2","app.b","B",space:201)])
        let p=try plan(record([saved("app.a","A",slot:2),saved("app.b","B",slot:3)]),s)
        XCTAssertEqual(p.plan.entries.map(\.targetSpace),[202,203])
        XCTAssertEqual(p.items.map(\.currentSlot),[1,1]); XCTAssertEqual(p.items.map(\.targetSlot),[2,3])
        XCTAssertTrue(p.items.allSatisfy{$0.moveSpace && $0.state == .ready})
        XCTAssertEqual(p.desktopsNow,3); XCTAssertEqual(p.desktopsNeeded,3)
    }
    func testTooFewDesktopsBlocksWithoutGuessing() throws {
        let s=snapshot([w("1:1","app.a","A",space:201),w("1:2","app.b","B",space:201)])
        let p=try plan(record([saved("app.a","A",slot:1),saved("app.b","B",slot:5)]),s)
        XCTAssertEqual(p.items[1].state,.blocked); XCTAssertTrue(p.items[1].reason.contains("请先在调度中心新建桌面"))
        XCTAssertEqual(p.plan.entries.count,1); XCTAssertEqual(p.desktopsNeeded,5)
    }
    func testOldRecordWithoutDesktopOrderIsBlocked() throws {
        let p=try plan(record([saved("app.a","A",slot:nil)]),snapshot([w("1:1","app.a","A",space:201)]))
        XCTAssertEqual(p.items[0].state,.blocked); XCTAssertEqual(p.items[0].reason,QuickRestorePlanner.oldRecordReason)
        XCTAssertTrue(p.plan.entries.isEmpty)
    }
    func testAlreadyInPlaceIsNotExecuted() throws {
        let target=Rect(0.5,0.1,0.4,0.5).fitted(in:visible)
        let p=try plan(record([saved("app.a","A",slot:1)]),snapshot([w("1:1","app.a","A",space:201,target)]))
        XCTAssertEqual(p.items[0].state,.alreadyInPlace); XCTAssertTrue(p.plan.entries.isEmpty)
    }
    func testCrossSpaceBlockedWhenBuildUnsupportedButSameSpaceResizeStillReady() throws {
        let s=snapshot([w("1:1","app.a","A",space:201),w("1:2","app.b","B",space:201)])
        let p=try QuickRestorePlanner.plan(record:record([saved("app.a","A",slot:1),saved("app.b","B",slot:2)]),monitor:monitor,displayToken:"ext",snapshot:s,allowCrossSpace:false,crossSpaceBlockReason:"未验证")
        XCTAssertEqual(p.items.map(\.state),[.ready,.blocked]); XCTAssertEqual(p.items[1].reason,"未验证")
        XCTAssertFalse(p.items[0].moveSpace); XCTAssertTrue(p.items[0].resize)
    }
    func testWrongMonitorThrows() {
        var r=record([saved("app.a","A",slot:1)]); r.monitor=MonitorIdentity(vendor:9,model:9,serial:9,name:"x")
        XCTAssertThrowsError(try plan(r,snapshot([])))
    }

    // MARK: identity scoring
    func testBundleMustMatch() throws {
        let p=try plan(record([saved("app.a","A",slot:1)]),snapshot([w("1:1","app.other","A",space:201)]))
        XCTAssertEqual(p.items[0].state,.missing)
    }
    func testDocumentPreferredForNonBrowsers() throws {
        let s=snapshot([w("1:1","app.ed","旧标题",doc:"file:///x",space:201),w("1:2","app.ed","report",doc:"file:///y",space:201)])
        let p=try plan(record([saved("app.ed","report",doc:"file:///x",slot:1)]),s)
        XCTAssertEqual(p.items[0].chosenToken,"1:1"); XCTAssertEqual(p.items[0].matchKind,.document)
    }
    func testDocumentMismatchNeedsConfirmationNotTitleGuess() throws {
        let s=snapshot([w("1:1","app.ed","report",doc:"file:///other",space:201)])
        let p=try plan(record([saved("app.ed","report",doc:"file:///x",slot:1)]),s)
        XCTAssertEqual(p.items[0].state,.needsConfirmation); XCTAssertNil(p.items[0].chosenToken); XCTAssertEqual(p.items[0].candidates.map(\.token),["1:1"])
    }
    func testBrowserTitleNormalization() {
        XCTAssertEqual(BrowserTitles.normalize("(3) Inbox - Gmail - Google Chrome"),"Inbox - Gmail")
        XCTAssertEqual(BrowserTitles.normalize("GitHub — Mozilla Firefox"),"GitHub")
        XCTAssertEqual(BrowserTitles.normalize("Docs - Profile 1 - Microsoft\u{200B} Edge"),"Docs - Profile 1")
        XCTAssertEqual(BrowserTitles.normalize("Docs and 3 more pages - Microsoft Edge"),"Docs")
        XCTAssertEqual(BrowserTitles.normalize("Google Chrome Help"),"Google Chrome Help")
        XCTAssertEqual(BrowserTitles.normalize("(12+) 新闻"),"新闻")
    }
    func testBrowserMatchesNormalizedTitle() throws {
        let s=snapshot([w("1:1","com.google.Chrome","(2) Inbox",space:203),w("1:2","com.google.Chrome","News",space:201)])
        let p=try plan(record([saved("com.google.Chrome","Inbox - Google Chrome",slot:1)]),s)
        XCTAssertEqual(p.items[0].chosenToken,"1:1"); XCTAssertEqual(p.items[0].matchKind,.browserTitle); XCTAssertEqual(p.items[0].state,.ready)
    }
    func testBrowserUrlDocumentIsNotPrimaryKey() throws {
        let s=snapshot([w("1:1","com.apple.Safari","Inbox",doc:"https://a.example/1",space:201),w("1:2","com.apple.Safari","Other",doc:"https://saved.example",space:201)])
        let p=try plan(record([saved("com.apple.Safari","Inbox",doc:"https://saved.example",slot:1)]),s)
        XCTAssertEqual(p.items[0].chosenToken,"1:1")
    }
    func testDuplicateTitlesTieBreakBySlotThenGeometry() throws {
        let target=Rect(0.5,0.1,0.4,0.5).fitted(in:visible)
        let s=snapshot([w("1:1","com.google.Chrome","New Tab",space:202),w("1:2","com.google.Chrome","New Tab",space:201,target),w("1:3","com.google.Chrome","New Tab",space:201)])
        let p=try plan(record([saved("com.google.Chrome","New Tab",slot:1)]),s)
        XCTAssertEqual(p.items[0].chosenToken,"1:2"); XCTAssertEqual(p.items[0].matchKind,.tieBreak); XCTAssertEqual(p.items[0].state,.alreadyInPlace)
    }
    func testDuplicateTitlesStillAmbiguousNeedsConfirmationWithCandidates() throws {
        let s=snapshot([w("1:1","com.google.Chrome","New Tab",space:202),w("1:2","com.google.Chrome","New Tab",space:203)])
        let p=try plan(record([saved("com.google.Chrome","New Tab",slot:1)]),s)
        XCTAssertEqual(p.items[0].state,.needsConfirmation); XCTAssertNil(p.items[0].chosenToken)
        XCTAssertEqual(Set(p.items[0].candidates.map(\.token)),["1:1","1:2"]); XCTAssertTrue(p.plan.entries.isEmpty)
    }
    func testBrowserTitleChangedPreselectsSlotGeometryButStillAsks() throws {
        let target=Rect(0.5,0.1,0.4,0.5).fitted(in:visible)
        let s=snapshot([w("1:1","com.google.Chrome","Something else",space:201,target),w("1:2","com.google.Chrome","Other",space:202)])
        let p=try plan(record([saved("com.google.Chrome","Inbox",slot:1)]),s)
        XCTAssertEqual(p.items[0].state,.needsConfirmation); XCTAssertEqual(p.items[0].chosenToken,"1:1"); XCTAssertEqual(p.items[0].matchKind,.slotGeometry)
    }
    func testUserChoiceResolvesAmbiguityAndIsTokenPinned() throws {
        let s=snapshot([w("1:1","com.google.Chrome","New Tab",space:202),w("1:2","com.google.Chrome","New Tab",space:203)])
        let p=try plan(record([saved("com.google.Chrome","New Tab",slot:1)]),s,choices:[0:.window("1:2")])
        XCTAssertEqual(p.items[0].state,.ready); XCTAssertEqual(p.items[0].matchKind,.userChoice)
        XCTAssertEqual(p.plan.entries[0].window?.token,"1:2"); XCTAssertEqual(p.plan.entries[0].tokenPinned,true)
    }
    func testUserSkipAndVanishedChoice() throws {
        let s=snapshot([w("1:1","app.a","A",space:201)])
        XCTAssertEqual(try plan(record([saved("app.a","A",slot:1)]),s,choices:[0:.skip]).items[0].state,.skippedByUser)
        XCTAssertEqual(try plan(record([saved("app.a","A",slot:1)]),s,choices:[0:.window("9:9")]).items[0].state,.needsConfirmation)
    }
    func testSameWindowClaimedTwiceNeedsConfirmation() throws {
        let s=snapshot([w("1:1","app.a","A",space:201),w("1:2","app.a","B",space:201)])
        let p=try plan(record([saved("app.a","A",slot:1),saved("app.a","B",slot:2)]),s,choices:[1:.window("1:1")])
        XCTAssertEqual(p.items.map(\.state),[.needsConfirmation,.needsConfirmation]); XCTAssertTrue(p.plan.entries.isEmpty)
    }
    func testIneligibleWindowsAreNotCandidates() throws {
        var mini=w("1:1","app.a","A",space:201); mini.minimized=true
        var sticky=w("1:2","app.a","A",space:201); sticky.spaceIDs=[201,202]
        let p=try plan(record([saved("app.a","A",slot:1)]),snapshot([mini,sticky]))
        XCTAssertEqual(p.items[0].state,.missing)
    }
    func testWindowOnOtherDisplayIsCrossDisplayAndExcludedFromAuto() throws {
        let s=snapshot([w("1:1","app.a","A",space:10,Rect(10,10,500,400)),w("1:2","app.b","B",space:201)])
        let p=try plan(record([saved("app.a","A",slot:1),saved("app.b","B",slot:2)]),s)
        XCTAssertTrue(p.items[0].crossDisplay); XCTAssertEqual(p.items[0].state,.ready)
        XCTAssertEqual(QuickRestorePlanner.autoSubset(p).entries.map{$0.window?.token},["1:2"])
    }

    // MARK: freeze preview + execute
    func testConfirmedChoicesFreezePreviewAndExecuteWithUndo() throws {
        let windows=MemoryWindows(snapshot([w("1:1","com.google.Chrome","New Tab",space:201),w("1:2","com.google.Chrome","New Tab",space:202),w("2:1","app.ed","doc",doc:"file:///d",space:203)]))
        let r=record([saved("com.google.Chrome","New Tab",slot:3),saved("app.ed","doc",doc:"file:///d",slot:1)])
        var preview=try plan(r,windows.state)
        XCTAssertEqual(preview.items.map(\.state),[.needsConfirmation,.ready])
        preview=try plan(r,windows.state,choices:[0:.window("1:2")])
        let frozen=try plan(r,windows.state,choices:preview.confirmedChoices)
        XCTAssertEqual(frozen.plan.entries.map{$0.window?.token},["1:2","2:1"])
        let spaces=SpaceSimulation(windows)
        let report=ManualRestorer.execute(frozen.plan,windows:windows,spaces:spaces,approved:true,persist:{_ in})
        XCTAssertEqual(report.results.map(\.outcome),[.verified,.verified],report.results.map(\.detail).joined())
        XCTAssertEqual(windows.state.windows.first{$0.token=="1:2"}?.spaceIDs,[203])
        XCTAssertEqual(windows.state.windows.first{$0.token=="2:1"}?.spaceIDs,[201])
        XCTAssertEqual(windows.state.windows.first{$0.token=="1:1"}?.spaceIDs,[201],"the other same-title window is untouched")
        let undo=ManualRestorer.undo(try XCTUnwrap(report.journal),windows:windows,spaces:spaces,approved:true,persist:{_ in})
        XCTAssertEqual(undo.results.map(\.outcome),[.verified,.verified])
        XCTAssertEqual(windows.state.windows.first{$0.token=="1:2"}?.spaceIDs,[202])
    }
    func testFrozenChoiceDoesNotFollowAWindowThatDisappeared() throws {
        let windows=MemoryWindows(snapshot([w("1:1","app.a","A",space:201)]))
        let r=record([saved("app.a","A",slot:2)])
        let preview=try plan(r,windows.state)
        windows.state.windows=[w("1:7","app.a","A",space:201)]
        let frozen=try plan(r,windows.state,choices:preview.confirmedChoices)
        XCTAssertEqual(frozen.items[0].state,.needsConfirmation); XCTAssertTrue(frozen.plan.entries.isEmpty)
    }
    func testUnpinnedDuplicateAppearingAfterPlanStillBlocksExecution() throws {
        let windows=MemoryWindows(snapshot([w("1:1","app.a","A",space:201)]))
        let p=try plan(record([saved("app.a","A",slot:1)]),windows.state)
        XCTAssertNil(p.plan.entries[0].tokenPinned)
        windows.state.windows.append(w("1:2","app.a","A",space:202))
        _=ManualRestorer.execute(p.plan,windows:windows,approved:true,persist:{_ in}); XCTAssertEqual(windows.writes,0)
    }
}
