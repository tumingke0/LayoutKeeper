// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// Switching between two different monitors that share one layout (home d:83238b at x=-204, office d:18c5e5 at x=-234).
final class MonitorSwitchReplayTests: XCTestCase {
    let t0=Date(timeIntervalSince1970:3_000_000)
    let home="shared-external@d:83238b", office="shared-external@d:18c5e5"
    func testQuickSwapToAnotherMonitorIsANewAttachNotABlip() {
        var s=AttachSession(initialMonitorKey:home)
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)            // unplug A
        s.note(wake:false,at:t0+1.5,fingerprint:"two-b",monitorKeyNow:office)   // plug B before A's unplug settled
        XCTAssertEqual(s.evaluate(at:t0+4.6,fingerprint:"two-b",monitorKey:office),.start(id:1,monitorKey:office,retry:false))
    }
    func testSwitchWithSettledUnplugAndExtraEventMidWaitIsOneSession() {
        var s=AttachSession(initialMonitorKey:home)
        var results=[String]()
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)
        guard case .ignored=s.evaluate(at:t0+3.2,fingerprint:"one",monitorKey:nil) else { return XCTFail() }
        s.note(wake:false,at:t0+60,fingerprint:"two-b",monitorKeyNow:office)
        XCTAssertEqual(s.evaluate(at:t0+63.2,fingerprint:"two-b",monitorKey:office),.start(id:1,monitorKey:office,retry:false))
        s.note(wake:false,at:t0+64,fingerprint:"two-b",monitorKeyNow:office)     // extra display event during window wait
        XCTAssertEqual(s.evaluate(at:t0+67.2,fingerprint:"two-b",monitorKey:office),.start(id:1,monitorKey:office,retry:true))
        if let r=s.finish(id:1,result:"ran restored=4") { results.append(r) }
        XCTAssertEqual(results,["attach #1 result=ran restored=4"])
        XCTAssertEqual(s.evaluate(at:t0+80,fingerprint:"two-b",monitorKey:office),.idle)
    }
}

extension QuickRestoreTests {
    /// Office monitor B: origin x=-234, only 4 desktops (layout needs 5). Windows migrated to the built-in screen,
    /// except one Chrome window that still carries monitor A's frame (x=-204) on B's desk 4.
    func officeSnapshot(desktops: Int) -> Snapshot {
        let b=Rect(-234,-1050,1920,1050)
        var spaces=[Space(id:4,displayToken:"builtin",active:true)]
        for i in 0..<desktops { spaces.append(Space(id:UInt64(160+i),displayToken:"officeB",active:i==0)) }
        let builtIn=Rect(0,33,1512,949)
        return Snapshot(session:UUID(),topology:"office-\(desktops)",displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:builtIn),Display(token:"officeB",name:"B",role:.external,visible:b)],spaces:spaces,windows:[
            w("3711:387","com.google.antigravity-ide","Alpha — Antigravity",space:4,builtIn),
            w("3711:388","com.google.antigravity-ide","Gamma — Antigravity",space:4,builtIn),
            w("9001:437","com.google.Chrome","New - Google Chrome - alex",space:4,builtIn),
            w("9001:514","com.google.Chrome","Other - Google Chrome - sam",space:163,Rect(-204,-1050,1920,1050))])
    }
    func switchRecord() -> MonitorLayoutRecord {
        var r=record([saved("com.google.antigravity-ide","Alpha — Antigravity",slot:3,Rect(0,0,1,1)),saved("com.google.antigravity-ide","Beta — Antigravity",slot:3,Rect(0,0,1,1)),
                      saved("com.google.Chrome","Old - Google Chrome - alex",slot:5,Rect(0,0,1,1)),saved("com.google.Chrome","Old2 - Google Chrome - sam",slot:4,Rect(0,0,1,1))])
        r.profile.windows[2].browserProfile="Default"; r.profile.windows[3].browserProfile="Profile 1"
        return r
    }
    func officePlan(_ desktops: Int,profiles: [String:String]) throws -> QuickRestorePlan {
        try QuickRestorePlanner.plan(record:switchRecord(),monitor:monitor,displayToken:"officeB",snapshot:officeSnapshot(desktops:desktops),allowCrossSpace:true,browserProfiles:profiles)
    }
    func testSwitchToOtherMonitorRestoresConfidentWindowsBeforeAndAfterAutoAddSpaces() throws {
        // Chrome 9001:514's profile is ambiguous right now (no profile map entry); 9001:437 resolves to Default.
        let before=try officePlan(4,profiles:["9001:437":"Default"])
        XCTAssertEqual(before.desktopsNeeded,5); XCTAssertEqual(before.missingDesktops,1,"auto-add spaces must run")
        let stale=before.items[3]
        XCTAssertNotEqual(stale.state,.alreadyInPlace,"A's frame (x=-204) on B (x=-234) is not in place")
        XCTAssertTrue(stale.resize,"window must be re-fitted to B")
        XCTAssertFalse(before.items.contains{ $0.state == .alreadyInPlace },"nothing counts as in place from A's stale frames")
        let autoBefore=QuickRestorePlanner.executionPlan(before,autoOnly:true,fresh:officeSnapshot(desktops:4))
        XCTAssertTrue(autoBefore.plan.entries.allSatisfy{ $0.targetDisplay == "officeB" && $0.targetFrame == Rect(-234,-1050,1920,1050) })
        XCTAssertTrue(autoBefore.savedIndex.contains(0),"title match restores onto B")
        // 0.6.9: the Chrome desk-5 group has no desk of its own yet; it stays put (never piled onto desk 4).
        XCTAssertEqual(before.items[2].state,.blocked); XCTAssertTrue(before.items[2].reason.contains("还缺 1 个桌面"))
        XCTAssertFalse(autoBefore.savedIndex.contains(2))
        // After auto-add spaces: 5 desktops, Chrome desk-5 window goes to its real desk.
        let after=try officePlan(5,profiles:["9001:437":"Default","9001:514":"Profile 1"])
        XCTAssertEqual(after.missingDesktops,0)
        XCTAssertEqual(after.items[2].targetSlot,5); XCTAssertEqual(after.items[2].state,.ready)
        let autoAfter=QuickRestorePlanner.executionPlan(after,autoOnly:true,fresh:officeSnapshot(desktops:5))
        XCTAssertEqual(Set(autoAfter.savedIndex),Set(after.items.filter{ QuickRestorePlanner.autoEligible($0) }.map(\.savedIndex)))
        XCTAssertTrue(autoAfter.savedIndex.contains(2) && autoAfter.savedIndex.contains(3),"both Chrome profiles restore on B after spaces are added")
    }
    func testAmbiguousChromeProfileStaysKnownAcrossMonitorSwitch() {
        ChromeProfileResolver.forgetRemembered(); defer { ChromeProfileResolver.forgetRemembered() }
        let r=ChromeProfileResolver(folders:[.init(id:"Profile 1",names:["sam"],session:Data("https://one.example/a".utf8)),.init(id:"Profile 2",names:["sam"],session:Data()) ])
        _=r.map([w("9001:514","com.google.Chrome","A - Google Chrome - sam",doc:"https://one.example/a",space:11)])   // learnt at home
        XCTAssertEqual(r.map([w("9001:514","com.google.Chrome","B - Google Chrome - sam",doc:"https://new.example/zz",space:163)]),["9001:514":"Profile 1"],"still known at the office")
    }
    /// 10/16 09:57 office replug: saved Antigravity t:83f032 had 3 same-app candidates, all on desk 3 with the saved
    /// geometry. 0.6.8 called it "in place". 0.6.9: none of the candidates shares its title, so it is not in place —
    /// it is reported as closed (stale) in auto mode; manual still asks.
    func testAutoReportsUnrelatedCandidatesAsClosedNotInPlace() throws {
        let b=Rect(-234,-1050,1920,1050)
        let spaces=[Space(id:4,displayToken:"builtin",active:true),Space(id:6,displayToken:"officeB",active:true),Space(id:7,displayToken:"officeB"),Space(id:8,displayToken:"officeB")]
        let s=Snapshot(session:UUID(),topology:"t",displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,33,1512,949)),Display(token:"officeB",name:"B",role:.external,visible:b)],spaces:spaces,windows:[
            w("3711:22406","com.google.antigravity-ide","X — Antigravity",space:8,b),w("3711:387","com.google.antigravity-ide","Alpha — Antigravity",space:8,b),w("3711:388","com.google.antigravity-ide","Y — Antigravity",space:8,b)])
        let rec=record([saved("com.google.antigravity-ide","Alpha — Antigravity",slot:3,Rect(0,0,1,1)),saved("com.google.antigravity-ide","Beta — Antigravity",slot:3,Rect(0,0,1,1))])
        let p=try QuickRestorePlanner.plan(record:rec,monitor:monitor,displayToken:"officeB",snapshot:s,allowCrossSpace:true)
        XCTAssertEqual(p.items[1].state,.needsConfirmation,"manual still asks")
        XCTAssertFalse(p.items[1].reason.contains("标题已变化"))
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:rec,snapshot:s,displayToken:"officeB")
        XCTAssertTrue(q.quieted.isEmpty); XCTAssertEqual(q.stale,[1])
        XCTAssertEqual(q.plan.items[1].state,.missing); XCTAssertTrue(q.plan.items[1].stale); XCTAssertEqual(q.plan.items[1].staleOthers,2)
        XCTAssertEqual(q.plan.staleSummary{ _ in "Antigravity" },["Antigravity：保存的 1 个窗口已关闭，现在开着的是另外 2 个窗口"])
    }
    /// Same-title duplicates are related by title, so they may still count as in place.
    func testAutoQuietsSameTitleDuplicatesWhenEveryCandidateIsInPlace() throws {
        let b=Rect(-234,-1050,1920,1050)
        let spaces=[Space(id:4,displayToken:"builtin",active:true),Space(id:6,displayToken:"officeB",active:true),Space(id:7,displayToken:"officeB"),Space(id:8,displayToken:"officeB")]
        let s=Snapshot(session:UUID(),topology:"t",displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,33,1512,949)),Display(token:"officeB",name:"B",role:.external,visible:b)],spaces:spaces,windows:[
            w("3711:1","com.google.antigravity-ide","Same — Antigravity",space:8,b),w("3711:2","com.google.antigravity-ide","Same — Antigravity",space:8,b)])
        let rec=record([saved("com.google.antigravity-ide","Same — Antigravity",slot:3,Rect(0,0,1,1))])
        let p=try QuickRestorePlanner.plan(record:rec,monitor:monitor,displayToken:"officeB",snapshot:s,allowCrossSpace:true)
        // Same title, same desk, same geometry for both: the tie-break cannot choose, so the plan asks.
        XCTAssertEqual(p.items[0].state,.needsConfirmation)
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:rec,snapshot:s,displayToken:"officeB")
        XCTAssertEqual(q.quieted,[0]); XCTAssertTrue(q.stale.isEmpty)
        var moved=s; moved.windows[1].spaceIDs=[7]
        let p2=try QuickRestorePlanner.plan(record:rec,monitor:monitor,displayToken:"officeB",snapshot:moved,allowCrossSpace:true)
        XCTAssertTrue(QuickRestorePlanner.quietAlreadyInPlace(p2,record:rec,snapshot:moved,displayToken:"officeB").quieted.isEmpty)
    }
}

extension MonitorSwitchReplayTests {
    /// Same-model monitors without serials can share a display ID: a hand swap (gap > 1 s) inside the debounce
    /// window must still open a session, while the 0.25 s blip stays ignored.
    func testSameIDSwapWithRealGapIsAnAttach() {
        var s=AttachSession(initialMonitorKey:home)
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)
        s.note(wake:false,at:t0+1.4,fingerprint:"two",monitorKeyNow:home)
        XCTAssertEqual(s.evaluate(at:t0+4.5,fingerprint:"two",monitorKey:home),.start(id:1,monitorKey:home,retry:false))
    }
    func testShortGapIsStillABlip() {
        var s=AttachSession(initialMonitorKey:home)
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)
        s.note(wake:false,at:t0+0.25,fingerprint:"two",monitorKeyNow:home)
        guard case .ignored(let n)=s.evaluate(at:t0+3.3,fingerprint:"two",monitorKey:home) else { return XCTFail() }
        XCTAssertTrue(n.hasPrefix("blip"))
        // Gap bookkeeping resets: a later plain event does not inherit it.
        s.note(wake:false,at:t0+10,fingerprint:"two",monitorKeyNow:home)
        guard case .ignored=s.evaluate(at:t0+13.3,fingerprint:"two",monitorKey:home) else { return XCTFail() }
    }
    func testGapSplitAcrossEventsUsesLongestDrop() {
        var s=AttachSession(initialMonitorKey:home)
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)
        s.note(wake:false,at:t0+0.5,fingerprint:"one",monitorKeyNow:nil)      // still gone: gap keeps counting from t0
        s.note(wake:false,at:t0+1.2,fingerprint:"two",monitorKeyNow:home)
        XCTAssertEqual(s.evaluate(at:t0+4.3,fingerprint:"two",monitorKey:home),.start(id:1,monitorKey:home,retry:false))
    }
    func testWakeAfterSleepOnSameMonitorRestoresOnce() {
        var s=AttachSession(initialMonitorKey:office)
        s.note(wake:true,at:t0,fingerprint:"two",monitorKeyNow:office)
        s.note(wake:false,at:t0+1,fingerprint:"two",monitorKeyNow:office)
        XCTAssertEqual(s.evaluate(at:t0+4.1,fingerprint:"two",monitorKey:office),.start(id:1,monitorKey:office,retry:false))
        XCTAssertNotNil(s.finish(id:1,result:"ran"))
        XCTAssertEqual(s.evaluate(at:t0+9,fingerprint:"two",monitorKey:office),.idle)
    }
}

extension MonitorSwitchReplayTests {
    func testFollowUpKeepsSessionOpenAndEndsOnce() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"b",monitorKeyNow:office)
        XCTAssertEqual(s.evaluate(at:t0+3.2,fingerprint:"b",monitorKey:office),.start(id:1,monitorKey:office,retry:false))
        XCTAssertTrue(s.beginFollowUp(id:1)); XCTAssertTrue(s.awaitingFollowUp)
        XCTAssertNotNil(s.open,"step 1 done but the session is still open")
        XCTAssertFalse(s.followUpArrived(id:2),"foreign arrival")
        XCTAssertTrue(s.followUpArrived(id:1)); XCTAssertFalse(s.followUpArrived(id:1),"arrives once")
        XCTAssertEqual(s.finish(id:1,result:"ran restored=4 autoSpaces=added1"),"attach #1 result=ran restored=4 autoSpaces=added1")
        XCTAssertNil(s.finish(id:1,result:"x"))
    }
    func testLateFollowUpAfterTimeoutIsIgnored() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"b",monitorKeyNow:office)
        _=s.evaluate(at:t0+3.2,fingerprint:"b",monitorKey:office)
        XCTAssertTrue(s.beginFollowUp(id:1))
        XCTAssertTrue(s.followUpArrived(id:1)); XCTAssertNotNil(s.finish(id:1,result:"ran autoSpaces=timeout"))   // timeout path
        XCTAssertFalse(s.followUpArrived(id:1),"late add result does not reopen or double-end")
    }
    func testTallyCountsEachWindowOnceLatestStepWins() {
        var t=RestoreTally()
        t.add(verified:["a","b","c"],failed:["d"])        // step 1: d not responding
        t.add(verified:["d"],failed:[])                   // retry: d ok
        XCTAssertEqual(t.restored,4); XCTAssertEqual(t.attempted,4)
        t.add(verified:["c"],failed:["b"])               // step 2 after adding desktops: c moved again, b failed
        XCTAssertEqual(t.verified,["a","c","d"]); XCTAssertEqual(t.failed,["b"]); XCTAssertEqual(t.attempted,4)
    }
}

extension QuickRestoreTests {
    func inPlaceFixture(live: [String]) -> (MonitorLayoutRecord,Snapshot,Rect) {
        let b=Rect(-234,-1050,1920,1050)
        let spaces=[Space(id:4,displayToken:"builtin",active:true),Space(id:6,displayToken:"officeB",active:true),Space(id:7,displayToken:"officeB"),Space(id:8,displayToken:"officeB")]
        let s=Snapshot(session:UUID(),topology:"t",displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,33,1512,949)),Display(token:"officeB",name:"B",role:.external,visible:b)],spaces:spaces,
                       windows:live.enumerated().map{ w("3711:\($0.offset)","com.google.antigravity-ide",$0.element,space:8,b) })
        let rec=record([saved("com.google.antigravity-ide","Alpha — Antigravity",slot:3,Rect(0,0,1,1)),saved("com.google.antigravity-ide","Beta — Antigravity",slot:3,Rect(0,0,1,1)),saved("com.google.antigravity-ide","Delta — Antigravity",slot:3,Rect(0,0,1,1))])
        return (rec,s,b)
    }
    /// 3 saved, 2 live (one matched by title, one renamed): the two unmatched saved windows share nothing with the
    /// renamed window, so both are reported closed; nothing is "in place" by geometry alone.
    func testQuietReportsClosedSavedWindowsAsStale() throws {
        let (rec,s,_)=inPlaceFixture(live:["Alpha — Antigravity","Renamed — Antigravity"])
        let p=try QuickRestorePlanner.plan(record:rec,monitor:monitor,displayToken:"officeB",snapshot:s,allowCrossSpace:true)
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:rec,snapshot:s,displayToken:"officeB")
        let states=q.plan.items.map(\.state)
        XCTAssertEqual(states,[.alreadyInPlace,.missing,.missing])
        XCTAssertEqual(q.stale,[1,2]); XCTAssertTrue(q.quieted.isEmpty)
        XCTAssertEqual(q.plan.items.filter(\.stale).map(\.staleOthers),[1,1])
        XCTAssertFalse(states.contains(.needsConfirmation))
    }
    /// A window already claimed by another saved window is not counted as a candidate for the unresolved ones.
    func testQuietIgnoresClaimedWindows() throws {
        let (rec,s,_)=inPlaceFixture(live:["Alpha — Antigravity","X — Antigravity","Y — Antigravity","Z — Antigravity"])
        let p=try QuickRestorePlanner.plan(record:rec,monitor:monitor,displayToken:"officeB",snapshot:s,allowCrossSpace:true)
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:rec,snapshot:s,displayToken:"officeB")
        XCTAssertTrue(q.missing.isEmpty,"3 unclaimed live windows ≥ 2 unresolved saved")
        XCTAssertFalse(q.plan.items.contains{ $0.state == .needsConfirmation })
    }
}

extension MonitorSwitchReplayTests {
    func testBusyTimeoutIsPerAttempt() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"b",monitorKeyNow:office)
        _=s.evaluate(at:t0+3.2,fingerprint:"b",monitorKey:office)
        XCTAssertFalse(s.noteBusy(at:t0+3.2)); XCTAssertFalse(s.noteBusy(at:t0+9))
        s.note(wake:false,at:t0+10,fingerprint:"b",monitorKeyNow:office)       // a display event restarts the attempt
        XCTAssertFalse(s.noteBusy(at:t0+14),"clock restarted at the new attempt")
        XCTAssertFalse(s.noteBusy(at:t0+23.9)); XCTAssertTrue(s.noteBusy(at:t0+24.1),"10 s of refusals within this attempt")
        s.notBusy(); XCTAssertFalse(s.noteBusy(at:t0+30))
        XCTAssertNotNil(s.finish(id:1,result:"x")); XCTAssertNil(s.busySince)
    }
}
