// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// Chrome windows are identified by profile folder, not by their (constantly changing) title.
extension QuickRestoreTests {
    func chromeRecord(_ folders: [String?],slots: [Int]) -> MonitorLayoutRecord {
        var r=record(zip(folders,slots).map{ _,slot in saved("com.google.Chrome","Old page - Google Chrome - sam",slot:slot) })
        for (i,f) in folders.enumerated() { r.profile.windows[i].browserProfile=f }
        return r
    }
    func testUniqueProfileWindowIsAutoEvenWhenTitleChanged() throws {
        let s=snapshot([w("1:1","com.google.Chrome","New page - Google Chrome - sam",space:202),w("1:2","com.google.Chrome","Other - Google Chrome - alex",space:203)])
        let p=try plan(chromeRecord(["Profile 1"],slots:[1]),s,browserProfiles:["1:1":"Profile 1","1:2":"Default"])
        XCTAssertEqual(p.items[0].chosenToken,"1:1"); XCTAssertEqual(p.items[0].matchKind,.browserProfile)
        XCTAssertTrue(QuickRestorePlanner.autoEligible(p.items[0]))
    }
    func testUniqueProfileWindowOnBuiltInScreenIsAutoAcrossDisplays() throws {
        let s=snapshot([w("1:1","com.google.Chrome","New page - Google Chrome - sam",space:10,Rect(10,10,500,400))])
        let p=try plan(chromeRecord(["Profile 1"],slots:[1]),s,browserProfiles:["1:1":"Profile 1"])
        XCTAssertTrue(p.items[0].crossDisplay); XCTAssertEqual(p.items[0].matchKind,.browserProfile)
        XCTAssertTrue(QuickRestorePlanner.autoEligible(p.items[0]))
    }
    func testProfileMismatchVetoesEvenAnExactTitle() throws {
        // Same title, but the live window belongs to another account: never taken.
        let s=snapshot([w("1:1","com.google.Chrome","Old page - Google Chrome - sam",space:202)])
        let p=try plan(chromeRecord(["Profile 1"],slots:[1]),s,browserProfiles:["1:1":"Profile 2"])
        XCTAssertNil(p.items[0].chosenToken); XCTAssertTrue(QuickRestorePlanner.autoSubset(p).entries.isEmpty)
        XCTAssertEqual(p.items[0].candidates.count,1)   // still offered in the manual choice list
    }
    func testSeveralWindowsOfProfileDisambiguatedByTitle() throws {
        let s=snapshot([w("1:1","com.google.Chrome","Old page - Google Chrome - sam",space:202),w("1:2","com.google.Chrome","X - Google Chrome - sam",space:202)])
        let p=try plan(chromeRecord(["Profile 1"],slots:[2]),s,browserProfiles:["1:1":"Profile 1","1:2":"Profile 1"])
        XCTAssertEqual(p.items[0].chosenToken,"1:1"); XCTAssertEqual(p.items[0].matchKind,.tieBreak)
    }
    func testSeveralWindowsOfProfileWithChangedTitlesAreNotAuto() throws {
        let s=snapshot([w("1:1","com.google.Chrome","A - Google Chrome - sam",space:202),w("1:2","com.google.Chrome","B - Google Chrome - sam",space:203)])
        let p=try plan(chromeRecord(["Profile 1"],slots:[1]),s,browserProfiles:["1:1":"Profile 1","1:2":"Profile 1"])
        XCTAssertTrue(QuickRestorePlanner.autoSubset(p).entries.isEmpty)
    }
    func testTwoSavedWindowsOfOneProfileDoNotBothClaimTheOnlyLiveOne() throws {
        let s=snapshot([w("1:1","com.google.Chrome","New - Google Chrome - sam",space:202)])
        let p=try plan(chromeRecord(["Profile 1","Profile 1"],slots:[1,2]),s,browserProfiles:["1:1":"Profile 1"])
        XCTAssertFalse(p.items.contains{ $0.matchKind == .browserProfile })
        XCTAssertTrue(QuickRestorePlanner.autoSubset(p).entries.isEmpty)
    }
    func testUnknownLiveProfileFallsBackToOldRules() throws {
        let s=snapshot([w("1:1","com.google.Chrome","New - Google Chrome - sam",space:202)])
        let p=try plan(chromeRecord(["Profile 1"],slots:[1]),s)
        XCTAssertNotEqual(p.items[0].matchKind,.browserProfile); XCTAssertTrue(QuickRestorePlanner.autoSubset(p).entries.isEmpty)
    }

    // MARK: resolver
    var resolver: ChromeProfileResolver { ChromeProfileResolver(folders:[
        .init(id:"Default",names:["alex","alex lee"],session:Data("https://shared.example/x".utf8)),
        .init(id:"Profile 1",names:["sam","sam lee"],session:Data("https://one.example/a ".utf8)+"Project board".data(using:.utf16LittleEndian)!),
        .init(id:"Profile 2",names:["sam","sam wu"],session:Data("https://two.example/b https://shared.example/x".utf8))]) }
    func testResolverSources() {
        let r=resolver
        XCTAssertEqual(r.resolve(url:"https://two.example/b",title:"B - Google Chrome - sam",titleProfile:"sam").source,.sessionsURL)
        // Active page not in the session file yet, but its title is.
        let t=r.resolve(url:"https://one.example/new-page",title:"Project board - Google Chrome - sam",titleProfile:"sam")
        XCTAssertEqual(t.folder,"Profile 1"); XCTAssertEqual(t.source,.sessionsTitle)
        // Unique display name in Local State.
        let n=r.resolve(url:"https://nowhere.example/zz",title:"Zz - Google Chrome - alex",titleProfile:"alex")
        XCTAssertEqual(n.folder,"Default"); XCTAssertEqual(n.source,.localStateName)
        // Shared "sam" with nothing in sessions: unknown, with a reason.
        let u=r.resolve(url:"https://nowhere.example/zz",title:"Zz - Google Chrome - sam",titleProfile:"sam")
        XCTAssertNil(u.folder); XCTAssertEqual(u.source,.unknown); XCTAssertTrue(u.reason.contains("nameIn2Profiles"))
        // Full Google name in the title picks the account.
        XCTAssertEqual(r.resolve(url:nil,title:"Zz - Google Chrome - sam wu",titleProfile:"sam wu").folder,"Profile 2")
        // URL in two profiles narrowed by title name.
        XCTAssertEqual(r.resolve(url:"https://shared.example/x",title:"S - Google Chrome - alex",titleProfile:"alex").folder,"Default")
        XCTAssertNil(r.resolve(url:"https://two.example/b",title:"B - Google Chrome (Incognito)",titleProfile:BrowserTitles.incognito).folder)
    }
    func testProfileStaysStickyForSameWindowWhenFreshResolutionIsAmbiguous() {
        ChromeProfileResolver.forgetRemembered(); defer { ChromeProfileResolver.forgetRemembered() }
        let r=resolver
        XCTAssertEqual(r.resolveAll([w("9001:514","com.google.Chrome","A - Google Chrome - sam",doc:"https://one.example/a",space:1)]).first?.1.source,.sessionsURL)
        let later=w("9001:514","com.google.Chrome","Zz - Google Chrome - sam",doc:"https://nowhere.example/zz",space:1)
        let res=r.resolveAll([later]).first!.1
        XCTAssertEqual(res.folder,"Profile 1"); XCTAssertEqual(res.source,.remembered)
        XCTAssertNil(r.resolveAll([w("9100:514","com.google.Chrome","Zz - Google Chrome - sam",doc:"https://nowhere.example/zz",space:1)]).first!.1.folder,"other window / relaunched Chrome")
        XCTAssertEqual(r.resolveAll([w("9001:514","com.google.Chrome","Zz - Google Chrome - alex",doc:"https://nowhere.example/zz",space:1)]).first!.1.folder,"Default","title profile name changed")
        XCTAssertNil(r.resolveAll([w("9001:514","com.google.Chrome","Zz - Google Chrome (Incognito)",doc:"https://nowhere.example/zz",space:1)]).first!.1.folder)
        ChromeProfileResolver.forgetRemembered()
        XCTAssertNil(r.resolveAll([later]).first!.1.folder,"a new session forgets")
    }
}
