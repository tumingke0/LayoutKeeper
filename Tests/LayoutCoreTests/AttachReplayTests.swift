// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// Replays of the real failures in restore-log.txt (10/15 10:29 and 22:20, 10/16 09:22, the 10/15 13:21 blip).
final class AttachSessionTests: XCTestCase {
    let t0=Date(timeIntervalSince1970:2_000_000)
    /// Drives a session like the coordinator: every `.start` is either cancelled (by the script) or finished.
    func settle(_ s: inout AttachSession,_ at: TimeInterval,_ fp: String,_ key: String?) -> AttachSession.Decision {
        s.evaluate(at:t0+at,fingerprint:fp,monitorKey:key)
    }
    // 10/16 09:22: plug in → settled → window-settle wait → 2nd display event cancels it → settle again on the same
    // monitor. Before: skipped as "monitor unchanged". Now: the same session starts again and ends with one result.
    func testReplay1016CancelledWaitRestartsSameSession() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"two",monitorKeyNow:"shared-external")
        XCTAssertEqual(settle(&s,3.2,"two","shared-external"),.start(id:1,monitorKey:"shared-external",retry:false))
        s.note(wake:false,at:t0+4.8,fingerprint:"two",monitorKeyNow:"shared-external")   // cancels the wait
        XCTAssertEqual(settle(&s,8.0,"two","shared-external"),.start(id:1,monitorKey:"shared-external",retry:true))
        XCTAssertEqual(s.finish(id:1,result:"ran restored=4"),"attach #1 result=ran restored=4")
        XCTAssertNil(s.open)
        XCTAssertNil(s.finish(id:1,result:"again"),"a session ends exactly once")
    }
    // 10/15 13:21: 2 screens → 1 → back to 2 within 0.25 s, same monitor: a blip, ignored with one log note.
    func testReplay1015BlipIsIgnored() {
        var s=AttachSession(initialMonitorKey:"shared-external")
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)
        s.note(wake:false,at:t0+0.25,fingerprint:"two",monitorKeyNow:"shared-external")
        guard case .ignored(let note)=settle(&s,3.5,"two","shared-external") else { return XCTFail() }
        XCTAssertTrue(note.hasPrefix("blip ignored"))
        XCTAssertNil(s.open)
    }
    func testResolutionChangeIsNotAnAttach() {
        var s=AttachSession(initialMonitorKey:"m")
        s.note(wake:false,at:t0,fingerprint:"a",monitorKeyNow:"m")
        guard case .ignored(let note)=settle(&s,3.2,"a","m") else { return XCTFail() }
        XCTAssertTrue(note.hasPrefix("same monitor"))
    }
    func testRealUnplugThenReplugIsANewAttach() {
        var s=AttachSession(initialMonitorKey:"m")
        s.note(wake:false,at:t0,fingerprint:"one",monitorKeyNow:nil)
        guard case .ignored=settle(&s,3.2,"one",nil) else { return XCTFail() }
        s.note(wake:false,at:t0+10,fingerprint:"two",monitorKeyNow:"m")
        XCTAssertEqual(settle(&s,13.2,"two","m"),.start(id:1,monitorKey:"m",retry:false))
    }
    func testWakeWithSameMonitorOpensSession() {
        var s=AttachSession(initialMonitorKey:"m")
        s.note(wake:true,at:t0,fingerprint:"two",monitorKeyNow:"m")
        XCTAssertEqual(settle(&s,3.2,"two","m"),.start(id:1,monitorKey:"m",retry:false))
    }
    func testBusyRequeueRetriesSameSession() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"two",monitorKeyNow:"m")
        XCTAssertEqual(settle(&s,3.2,"two","m"),.start(id:1,monitorKey:"m",retry:false))
        s.requeue(at:t0+3.3,delay:1)
        XCTAssertEqual(settle(&s,3.5,"two","m"),.wait(until:t0+4.3))
        XCTAssertEqual(settle(&s,4.4,"two","m"),.start(id:1,monitorKey:"m",retry:true))
    }
    func testUnplugDuringOpenSessionClosesItWithAResult() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"two",monitorKeyNow:"m")
        _=settle(&s,3.2,"two","m")
        s.note(wake:false,at:t0+4,fingerprint:"one",monitorKeyNow:nil)
        XCTAssertEqual(settle(&s,7.2,"one",nil),.closed(id:1,line:"attach #1 result=skipped reason=unplugged-before-restore"))
    }
    func testOtherMonitorReplacesOpenSession() {
        var s=AttachSession(initialMonitorKey:nil)
        s.note(wake:false,at:t0,fingerprint:"a",monitorKeyNow:"m1")
        _=settle(&s,3.2,"a","m1")
        s.note(wake:false,at:t0+4,fingerprint:"b",monitorKeyNow:"m2")
        guard case .closed(1,let line)=settle(&s,7.2,"b","m2") else { return XCTFail() }
        XCTAssertTrue(line.contains("replaced-by-other-monitor"))
        XCTAssertEqual(s.startOpened(),.start(id:2,monitorKey:"m2",retry:false))
    }
    /// Invariant: over a random-ish script of events, cancellations and finishes, every opened session ends with
    /// exactly one result (finish or closed) and no session is started after it ended.
    func testExactlyOneResultPerAttach() {
        var s=AttachSession(initialMonitorKey:nil,settleInterval:1)
        var opened=Set<Int>(), ended=[Int:Int]()
        var time: TimeInterval=0
        let keys: [String?]=["m",nil,"m","m","n",nil,"m","m"]
        for (step,key) in keys.enumerated() {
            for round in 0..<3 {
                time+=0.3; s.note(wake:step%3==0,at:t0+time,fingerprint:"\(key ?? "-")",monitorKeyNow:key)
                time+=1.5
                var d=s.evaluate(at:t0+time,fingerprint:"\(key ?? "-")",monitorKey:key)
                if case .closed(let id,_)=d { ended[id,default:0]+=1; d=s.startOpened() }
                if case .start(let id,_,_)=d {
                    XCTAssertNil(ended[id],"no start after end"); opened.insert(id)
                    if round == 2 { if s.finish(id:id,result:"ran") != nil { ended[id,default:0]+=1 } }
                    // rounds 0 and 1: cancelled by the next event
                }
            }
        }
        if let o=s.open { if s.finish(id:o.id,result:"ran") != nil { ended[o.id,default:0]+=1 } }
        XCTAssertFalse(opened.isEmpty)
        for id in opened { XCTAssertEqual(ended[id],1,"attach #\(id) must end exactly once") }
    }
}

extension QuickRestoreTests {
    /// 10/15 22:20 at home: windows still on the built-in screen, titles changed. Two Antigravity windows (title +
    /// elimination), two Chrome profiles. Before: execution re-matched, every pin became userChoice → nothing ran.
    func replayRecord() -> MonitorLayoutRecord {
        var r=record([saved("com.google.antigravity-ide","Alpha — Antigravity",slot:1),saved("com.google.antigravity-ide","Beta — Antigravity",slot:1),
                      saved("com.google.Chrome","Old - Google Chrome - alex",slot:2),saved("com.google.Chrome","Old2 - Google Chrome - sam",slot:3)])
        r.profile.windows[2].browserProfile="Default"; r.profile.windows[3].browserProfile="Profile 1"
        return r
    }
    func replayLive(_ suffix: String = "") -> Snapshot {
        snapshot([w("3711:387","com.google.antigravity-ide","Alpha — Antigravity",space:10,Rect(10,10,500,400)),
                  w("3711:388","com.google.antigravity-ide","Gamma\(suffix) — Antigravity",space:10,Rect(10,10,500,400)),
                  w("9001:437","com.google.Chrome","New\(suffix) - Google Chrome - alex",space:10,Rect(10,10,500,400)),
                  w("9001:514","com.google.Chrome","Other\(suffix) - Google Chrome - sam",space:10,Rect(10,10,500,400))])
    }
    func testReplay1015AutoRunsWhatThePreviewConfirmed() throws {
        let preview=try plan(replayRecord(),replayLive(),browserProfiles:["9001:437":"Default","9001:514":"Profile 1"])
        XCTAssertTrue(preview.items.allSatisfy{ $0.crossDisplay })
        let autoPreview=QuickRestorePlanner.autoSubset(preview).entries.count
        XCTAssertGreaterThanOrEqual(autoPreview,2,"title + Chrome profile matches are confident even across displays")
        // Titles change again between preview and execution: no re-match, so nothing is lost.
        let fresh=replayLive(" (changed)")
        let auto=QuickRestorePlanner.executionPlan(preview,autoOnly:true,fresh:fresh)
        let manual=QuickRestorePlanner.executionPlan(preview,autoOnly:false,fresh:fresh)
        XCTAssertEqual(auto.plan.entries.count,autoPreview)
        XCTAssertTrue(auto.gone.isEmpty)
        XCTAssertTrue(auto.plan.entries.allSatisfy{ $0.tokenPinned == true && $0.status == .ready })
        XCTAssertTrue(Set(auto.savedIndex).isSubset(of:Set(manual.savedIndex)),"auto is a subset of manual")
        XCTAssertEqual(manual.savedIndex.count,preview.readyCount)
        XCTAssertEqual(auto.plan.session,fresh.session)
        XCTAssertEqual(auto.plan.entries.first{ $0.window?.token=="9001:437" }?.window?.selector.title.contains("(changed)"),true,"bound to the live window")
    }
    /// 10/15 10:29 at the office: 3 ready, one not in the layout any more. A closed window is the only thing dropped.
    func testReplay1015OfficeOnlyClosedWindowsAreDropped() throws {
        let preview=try plan(replayRecord(),replayLive(),browserProfiles:["9001:437":"Default","9001:514":"Profile 1"])
        var fresh=replayLive(); fresh.windows.removeAll{ $0.token=="9001:437" }
        let auto=QuickRestorePlanner.executionPlan(preview,autoOnly:true,fresh:fresh)
        XCTAssertEqual(auto.gone,[2])
        XCTAssertEqual(auto.plan.entries.filter{ $0.status == .ready }.count,QuickRestorePlanner.autoSubset(preview).entries.count-1)
    }
    func testManualOnlyMatchesStayOutOfAuto() throws {
        let preview=try plan(replayRecord(),replayLive(),browserProfiles:["9001:437":"Default","9001:514":"Profile 1"])
        for item in preview.items where item.state == .ready {
            let expected: Bool
            switch item.matchKind {
            case .document,.title,.browserTitle,.browserProfile,.onlyWindow: expected=true
            case .elimination,.slotGeometry: expected=item.autoCertain
            default: expected=false
            }
            XCTAssertEqual(QuickRestorePlanner.autoEligible(item),expected,"\(item.matchKind)")
        }
    }
}
