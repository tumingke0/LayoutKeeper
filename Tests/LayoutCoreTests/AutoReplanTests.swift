// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// Regression (restore-log 2026-10-15 22:20): the auto preview had runnable items, but the execute re-plan pinned
/// them as user choices (manual-only), so auto restore found nothing to do while manual restore worked.
extension QuickRestoreTests {
    func homeScenario() -> (MonitorLayoutRecord,Snapshot,[String:String]) {
        var r=record([
            saved("com.google.antigravity","proj — Antigravity",slot:1),
            saved("com.google.Chrome","Old A - Google Chrome - sam",slot:2),
            saved("com.google.Chrome","Old B - Google Chrome - alex",slot:3),
            saved("app.ed","notes",slot:1),
            saved("app.ed","todo",slot:2),
        ])
        r.profile.windows[1].browserProfile="Profile 1"
        let s=snapshot([
            w("1:1","com.google.antigravity","proj — Antigravity",space:202),
            w("2:1","com.google.Chrome","New A - Google Chrome - sam",space:203),
            w("2:2","com.google.Chrome","New B - Google Chrome - alex",space:201),
            w("3:1","app.ed","notes",space:202),
            w("3:2","app.ed","renamed",space:201),
        ])
        return (r,s,["2:1":"Profile 1"])
    }
    func testAutoReplanKeepsPreviewMatchKinds() throws {
        let (r,s,bp)=homeScenario()
        let preview=try plan(r,s,browserProfiles:bp)
        let auto=QuickRestorePlanner.autoSubset(preview).entries.count
        XCTAssertEqual(auto,preview.readyCount,preview.items.map{"\($0.matchKind):\(RestoreLog.autoReason($0))"}.joined(separator:" "))
        let frozen=try plan(r,s,choices:preview.confirmedChoices,browserProfiles:bp)
        XCTAssertEqual(QuickRestorePlanner.autoSubset(frozen).entries.count,0,"old behaviour: pins are userChoice")
        let fixed=try QuickRestorePlanner.plan(record:r,monitor:monitor,displayToken:"ext",snapshot:s,choices:preview.confirmedChoices,allowCrossSpace:true,browserProfiles:bp,pinnedMatches:preview.confirmedMatches)
        XCTAssertEqual(QuickRestorePlanner.autoSubset(fixed).entries.count,auto)
        XCTAssertEqual(fixed.items.map(\.matchKind),preview.items.map(\.matchKind))
    }
    func testElimiationAndUniqueChromeUserAreAutoEligible() throws {
        let (r,s,bp)=homeScenario()
        let p=try plan(r,s,browserProfiles:bp)
        XCTAssertEqual(p.items[2].matchKind,.slotGeometry); XCTAssertTrue(QuickRestorePlanner.autoEligible(p.items[2]))
        XCTAssertEqual(p.items[4].matchKind,.elimination); XCTAssertTrue(QuickRestorePlanner.autoEligible(p.items[4]))
    }
    func testPinnedChromeWindowWithNewProfileIsVetoed() throws {
        let (r,s,bp)=homeScenario()
        let preview=try plan(r,s,browserProfiles:bp)
        let fixed=try QuickRestorePlanner.plan(record:r,monitor:monitor,displayToken:"ext",snapshot:s,choices:preview.confirmedChoices,allowCrossSpace:true,browserProfiles:["2:1":"Profile 9"],pinnedMatches:preview.confirmedMatches)
        XCTAssertNil(fixed.items[1].chosenToken); XCTAssertFalse(QuickRestorePlanner.autoSubset(fixed).entries.contains{$0.window?.token=="2:1"})
    }
}
