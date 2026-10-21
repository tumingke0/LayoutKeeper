// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class SharedLayoutTests: XCTestCase {
    let office=MonitorIdentity(vendor:1,model:2,serial:3,name:"DELL")
    let home=MonitorIdentity(vendor:7,model:8,serial:9,name:"LG")
    let visible=Rect(1200,0,2560,1440)
    func snapshot(extSpaces: [UInt64],windows: [ObservedWindow],visible: Rect? = nil) -> Snapshot {
        Snapshot(session:UUID(),topology:"t",displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,0,1200,800)),Display(token:"ext",name:"Ext",role:.external,visible:visible ?? self.visible)],
                 spaces:[Space(id:10,displayToken:"builtin",active:true)]+extSpaces.enumerated().map{ Space(id:$0.element,displayToken:"ext",active:$0.offset==0) },windows:windows)
    }
    func w(_ token: String,_ bundle: String,_ title: String,space: UInt64,_ frame: Rect = Rect(1300,100,800,600)) -> ObservedWindow {
        ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title),frame:frame,spaceIDs:[space],processStartedAt:Date(timeIntervalSince1970:1000))
    }
    func saved(_ bundle: String,_ title: String,slot: Int,_ frame: Rect = Rect(0.5,0.1,0.4,0.5)) -> SavedWindow {
        SavedWindow(selector:WindowSelector(bundleID:bundle,title:title),displayRole:.external,desktopLabel:"组-\(slot)",normalizedFrame:frame,desktopIndex:slot)
    }
    func sharedRecord(_ windows: [SavedWindow]) -> MonitorLayoutRecord { MonitorLayoutRecord(monitor:.sharedExternal,profile:Profile(location:"共用",windows:windows)) }

    func testSharedIdentityHasStableKeyAndValidates() throws {
        XCTAssertEqual(MonitorIdentity.sharedExternal.key,"shared-external")
        XCTAssertTrue(MonitorIdentity.sharedExternal.isSharedExternal); XCTAssertFalse(office.isSharedExternal)
        try sharedRecord([saved("app.a","A",slot:1)]).validate()
    }
    func testEffectiveIdentityOnlyWithExactlyOneExternalMonitor() {
        XCTAssertEqual(SharedLayout.effective([office],mode:.sharedExternal),[.sharedExternal])
        XCTAssertEqual(SharedLayout.effective([home],mode:.sharedExternal),[.sharedExternal])
        XCTAssertEqual(SharedLayout.effective([office],mode:.perMonitor),[office])
        XCTAssertEqual(SharedLayout.effective([office,home],mode:.sharedExternal),[office,home])   // fallback to per-screen
        XCTAssertEqual(SharedLayout.effective([],mode:.sharedExternal),[])
        XCTAssertTrue(SharedLayout.fellBack(externalCount:2,mode:.sharedExternal)); XCTAssertFalse(SharedLayout.fellBack(externalCount:1,mode:.sharedExternal))
    }
    func testMissingDesktops() {
        XCTAssertEqual(SharedLayout.missingDesktops(needed:6,available:2),4)
        XCTAssertEqual(SharedLayout.missingDesktops(needed:2,available:6),0)
    }
    /// Space IDs differ between the office and home screens; windows go to the same ordinal, scaled to the new resolution.
    func testSharedRecordRestoresByOrdinalOnAnotherMonitorWithDifferentIDsAndResolution() throws {
        let r=sharedRecord([saved("app.a","A",slot:1),saved("app.b","B",slot:3,Rect(0,0,0.5,1))])
        let s=snapshot(extSpaces:[501,502,503],windows:[w("1:1","app.a","A",space:501),w("1:2","app.b","B",space:501)],visible:Rect(1200,0,1920,1080))
        let p=try QuickRestorePlanner.plan(record:r,monitor:.sharedExternal,displayToken:"ext",snapshot:s,allowCrossSpace:true)
        XCTAssertEqual(p.items.map(\.targetSlot),[1,3])
        XCTAssertEqual(p.plan.entries.last?.targetSpace,503)
        XCTAssertEqual(p.items[1].targetFrame,Rect(1200,0,960,1080))
        XCTAssertEqual(p.missingDesktops,0)
    }
    /// 0.6.11: too few desks: each group waits for the desk at its own position; nothing is compressed or piled.
    func testTooFewSpacesKeepsPositionsAndLeavesTheRestUntouched() throws {
        let r=sharedRecord([saved("app.a","A",slot:1),saved("app.b","B",slot:4),saved("app.c","C",slot:6)])
        let s=snapshot(extSpaces:[501,502],windows:[w("1:1","app.a","A",space:501),w("1:2","app.b","B",space:501),w("1:3","app.c","C",space:501)])
        let p=try QuickRestorePlanner.plan(record:r,monitor:.sharedExternal,displayToken:"ext",snapshot:s,allowCrossSpace:true)
        XCTAssertEqual(p.items.map(\.state),[.ready,.blocked,.blocked])
        XCTAssertEqual(p.items[0].targetSlot,1); XCTAssertEqual(p.items[0].deskMapping,.position)
        XCTAssertNil(p.items[1].targetSlot); XCTAssertTrue(p.items[1].reason.contains("第 4 个桌面还没有（还缺 4 个桌面）"))
        XCTAssertEqual(p.plan.entries.map(\.targetSpace),[501])
        XCTAssertEqual(p.desktopsNeeded,6); XCTAssertEqual(p.missingDesktops,4)
        XCTAssertFalse(p.items.contains{ $0.actionText.contains("最后一个桌面") })
    }
    func testSingleGroupWhoseDeskIsMissingWaitsForIt() throws {
        let r=sharedRecord([saved("app.b","B",slot:4)])
        let p=try QuickRestorePlanner.plan(record:r,monitor:.sharedExternal,displayToken:"ext",snapshot:snapshot(extSpaces:[501],windows:[w("1:2","app.b","B",space:501)]),allowCrossSpace:true)
        XCTAssertEqual(p.items[0].state,.blocked); XCTAssertNil(p.items[0].targetSlot); XCTAssertEqual(p.missingDesktops,3)
    }
    func testAddingSpacesLaterMapsToSavedOrdinal() throws {
        let r=sharedRecord([saved("app.b","B",slot:3)])
        let before=try QuickRestorePlanner.plan(record:r,monitor:.sharedExternal,displayToken:"ext",snapshot:snapshot(extSpaces:[501,502],windows:[w("1:2","app.b","B",space:501)]),allowCrossSpace:true)
        XCTAssertNil(before.items[0].targetSlot); XCTAssertEqual(before.missingDesktops,1)
        // An old record (ordinal only): once the saved ordinal exists again, the window goes there.
        let after=try QuickRestorePlanner.plan(record:r,monitor:.sharedExternal,displayToken:"ext",snapshot:snapshot(extSpaces:[501,502,509],windows:[w("1:2","app.b","B",space:502)]),allowCrossSpace:true)
        XCTAssertEqual(after.items[0].targetSlot,3); XCTAssertEqual(after.plan.entries.first?.targetSpace,509)
        XCTAssertEqual(after.missingDesktops,0)
    }
    func testMigratedSpacesDetection() {
        let before=SpaceCensus(external:[201,202,203,204,205,206],builtIn:[10],externalCount:1)
        XCTAssertEqual(SpaceCensus.migratedToBuiltIn(before:before,after:SpaceCensus(external:[],builtIn:[10,201,202,203,204,205,206],externalCount:0)),6)
        // IDs re-issued by macOS: fall back to the count difference.
        XCTAssertEqual(SpaceCensus.migratedToBuiltIn(before:before,after:SpaceCensus(external:[],builtIn:[10,301,302],externalCount:0)),2)
        XCTAssertEqual(SpaceCensus.migratedToBuiltIn(before:before,after:SpaceCensus(external:[],builtIn:[10],externalCount:0)),0)
        XCTAssertEqual(SpaceCensus.migratedToBuiltIn(before:before,after:before),0)   // not an unplug
    }
    func testCensusCountsOnlyOrdinarySpacesPerRole() {
        let displays=[Display(token:"b",name:"b",role:.builtIn,visible:Rect(0,0,1,1)),Display(token:"e",name:"e",role:.external,visible:Rect(0,0,1,1))]
        let c=SpaceCensus.take(displays,[Space(id:1,displayToken:"b"),Space(id:2,displayToken:"e"),Space(id:3,displayToken:"e",kind:.fullScreenOrSplit),Space(id:4,displayToken:"e")],externalCount:1)
        XCTAssertEqual(c.external,[2,4]); XCTAssertEqual(c.builtIn,[1])
    }
    func testSeedCopiesPreferredScreenWithoutTouchingIt() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("screens")
        defer { try? FileManager.default.removeItem(at:root.deletingLastPathComponent()) }
        let library=ScreenLibrary(root:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let officeRecord=MonitorLayoutRecord(monitor:office,savedAt:Date(timeIntervalSince1970:100),profile:Profile(location:"o",windows:[saved("app.a","A",slot:2)]))
        let homeRecord=MonitorLayoutRecord(monitor:home,savedAt:Date(timeIntervalSince1970:200),profile:Profile(location:"h",windows:[saved("app.b","B",slot:1)]))
        try MonitorLayoutStore.save(officeRecord,to:library.currentURL(office.key))
        try MonitorLayoutStore.save(homeRecord,to:library.currentURL(home.key))
        let officeBytes=try Data(contentsOf:library.currentURL(office.key))
        XCTAssertEqual(try SharedLayout.seed(library:library,preferredKey:office.key),office.key)
        let shared=try MonitorLayoutStore.load(from:library.currentURL("shared-external"))
        XCTAssertTrue(shared.monitor.isSharedExternal); XCTAssertEqual(shared.profile.windows.first?.desktopIndex,2)
        XCTAssertEqual(try Data(contentsOf:library.currentURL(office.key)),officeBytes)
        XCTAssertNil(try SharedLayout.seed(library:library,preferredKey:home.key))   // never overwrites
        XCTAssertTrue(library.screens(connectedKey:"shared-external"){ $0.name }.contains{ $0.key=="shared-external" && $0.connected })
    }
    func testSeedFallsBackToMostRecentScreen() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("screens")
        defer { try? FileManager.default.removeItem(at:root.deletingLastPathComponent()) }
        let library=ScreenLibrary(root:root)
        XCTAssertNil(try SharedLayout.seed(library:library,preferredKey:nil))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try MonitorLayoutStore.save(MonitorLayoutRecord(monitor:office,savedAt:Date(timeIntervalSince1970:100),profile:Profile(location:"o",windows:[saved("app.a","A",slot:1)])),to:library.currentURL(office.key))
        try MonitorLayoutStore.save(MonitorLayoutRecord(monitor:home,savedAt:Date(timeIntervalSince1970:200),profile:Profile(location:"h",windows:[saved("app.b","B",slot:1)])),to:library.currentURL(home.key))
        XCTAssertEqual(try SharedLayout.seed(library:library,preferredKey:"monitor-unknown"),home.key)
    }
}
