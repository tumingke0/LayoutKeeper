// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// Reproduces the 0.2.0 (7) field bug: one Finder window (no process launch date) in a batch made the
/// all-or-nothing permit builder throw readbackUnavailable, so no window moved.
final class MoveScopeTests: XCTestCase {
    let q=QuickRestoreTests()
    struct PermitFailure: Error {}
    func mixedFixture() -> (MemoryWindows,MonitorLayoutRecord) {
        var finder=q.w("691:1","com.apple.finder","下载",space:202); finder.processStartedAt=nil
        let windows=[
            q.w("1:1","com.google.Chrome","Sandbox",space:201),            // cross-Space move → desktop 3
            q.w("1:2","com.google.Chrome","新闻",space:10,Rect(10,10,500,400)), // on the built-in screen → external desktop 2
            q.w("2:1","com.example.ide","IDE",space:202),       // cross-Space move → desktop 1
            finder,                                                         // cross-Space move → desktop 1, no launch date
            q.w("3:1","com.apple.systempreferences","设置",space:201)      // same desktop, resize only
        ]
        let r=q.record([q.saved("com.google.Chrome","Sandbox",slot:3),q.saved("com.google.Chrome","新闻",slot:2),q.saved("com.example.ide","IDE",slot:1),
                        q.saved("com.apple.finder","下载",slot:1),q.saved("com.apple.systempreferences","设置",slot:1)])
        return (MemoryWindows(q.snapshot(windows)),r)
    }
    func testPreviewFlagsFinderCrossSpaceAsBlockedButOthersReady() throws {
        let (w,r)=mixedFixture()
        let p=try q.plan(r,w.state)
        XCTAssertEqual(p.items.map(\.state),[.ready,.ready,.ready,.blocked,.ready])
        XCTAssertTrue(p.items[3].reason.contains("没有可验证的进程启动时间"))
        XCTAssertTrue(p.items[1].crossDisplay)
        XCTAssertFalse(p.plan.entries.contains{$0.window?.token=="691:1"})
    }
    func testFinderSameDesktopResizeStaysReady() throws {
        var finder=q.w("691:1","com.apple.finder","下载",space:201); finder.processStartedAt=nil
        let p=try q.plan(q.record([q.saved("com.apple.finder","下载",slot:1)]),q.snapshot([finder]))
        XCTAssertEqual(p.items[0].state,.ready); XCTAssertFalse(p.items[0].moveSpace)
    }
    func testMixedBatchOneUndeterminableItemDoesNotAbortOthers() throws {
        let (w,r)=mixedFixture()
        // Build the executable plan as the old flow would have (Finder included as ready), to prove partition isolates it.
        var plan=try q.plan(r,w.state).plan
        var finder=PlanEntry(saved:r.profile.windows[3],status:.ready,reason:"",window:w.state.windows[3],targetSpace:201,targetDisplay:"ext",targetFrame:Rect(1300,100,700,400))
        finder.tokenPinned=nil; plan.entries.append(finder)
        let split=MoveScope.partition(plan,snapshot:w.state) { entry -> String in
            if entry.window?.token=="2:1" { throw PermitFailure() }   // a second, unexpected per-item failure
            return entry.window!.token
        }
        XCTAssertEqual(Set(split.permits),["1:1","1:2"])
        XCTAssertEqual(split.blocked.count,2)
        XCTAssertTrue(split.plan.entries.first{$0.window?.token=="691:1"}!.reason.contains("没有可验证的进程启动时间"))
        XCTAssertEqual(split.plan.entries.first{$0.window?.token=="2:1"}!.status,.blocked)
        XCTAssertEqual(split.plan.entries.first{$0.window?.token=="3:1"}!.status,.ready,"same-desktop resize needs no permit")
        let spaces=SpaceSimulation(w)
        let report=ManualRestorer.execute(split.plan,windows:w,spaces:spaces,approved:true,persist:{_ in})
        let byToken=Dictionary(uniqueKeysWithValues:zip(split.plan.entries.map{$0.window!.token},report.results))
        XCTAssertEqual(byToken["1:1"]?.outcome,.verified); XCTAssertEqual(byToken["1:2"]?.outcome,.verified); XCTAssertEqual(byToken["3:1"]?.outcome,.verified)
        XCTAssertEqual(byToken["691:1"]?.outcome,.blocked); XCTAssertTrue(byToken["691:1"]!.detail.contains("无法跨桌面移动"))
        XCTAssertEqual(byToken["2:1"]?.outcome,.blocked)
        XCTAssertEqual(w.state.windows.first{$0.token=="691:1"}?.spaceIDs,[202],"Finder untouched")
        XCTAssertEqual(w.state.windows.first{$0.token=="2:1"}?.spaceIDs,[202])
        XCTAssertEqual(w.state.windows.first{$0.token=="1:2"}?.spaceIDs,[202],"built-in screen window moved to external desktop 2")
        XCTAssertEqual(spaces.moves,2)
        XCTAssertEqual(report.journal?.canUndo,true)
    }
    func testProblemReasons() {
        let s=q.snapshot([])
        var w=q.w("1:1","a","A",space:201)
        XCTAssertNil(MoveScope.problem(window:w,targetSpace:202,targetDisplay:"ext",snapshot:s))
        XCTAssertNil(MoveScope.problem(window:q.w("1:2","a","A",space:10),targetSpace:202,targetDisplay:"ext",snapshot:s),"built-in screen Spaces are known ordinary Spaces")
        XCTAssertNotNil(MoveScope.problem(window:w,targetSpace:290,targetDisplay:"ext",snapshot:s),"fullscreen Space is not a target")
        XCTAssertNotNil(MoveScope.problem(window:w,targetSpace:10,targetDisplay:"ext",snapshot:s),"target must be on the external display")
        w.spaceIDs=[999]; XCTAssertNotNil(MoveScope.problem(window:w,targetSpace:202,targetDisplay:"ext",snapshot:s))
        w.spaceIDs=[201,202]; XCTAssertNotNil(MoveScope.problem(window:w,targetSpace:202,targetDisplay:"ext",snapshot:s))
    }
}
