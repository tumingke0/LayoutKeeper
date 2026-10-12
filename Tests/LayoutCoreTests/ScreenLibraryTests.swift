// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class ScreenLibraryTests: XCTestCase {
    var dir: URL!
    var lib: ScreenLibrary!
    let home=MonitorIdentity(vendor:4268,model:53378,serial:1,name:"DELL SE2416H")
    let office=MonitorIdentity(vendor:7789,model:1234,serial:9,name:"LG UltraFine")
    override func setUpWithError() throws {
        dir=FileManager.default.temporaryDirectory.appendingPathComponent("lk-lib-\(UUID().uuidString)",isDirectory:true)
        lib=ScreenLibrary(root:dir.appendingPathComponent("screens",isDirectory:true),historyLimit:3)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:dir) }
    func record(_ m: MonitorIdentity,_ count: Int,desktops: Int = 1,at seconds: TimeInterval) -> MonitorLayoutRecord {
        let windows=(0..<count).map { i in
            SavedWindow(selector:WindowSelector(bundleID:"com.example.app\(i)",title:"W\(i)"),displayRole:.external,desktopLabel:"g\(i % desktops)",
                        normalizedFrame:Rect(0.1,0.1,0.5,0.5),desktopIndex:(i % desktops)+1)
        }
        return MonitorLayoutRecord(monitor:m,savedAt:Date(timeIntervalSince1970:seconds),profile:Profile(location:m.name,windows:windows))
    }

    func testListPutsConnectedFirstThenNewestAndUsesDisplayNames() throws {
        try lib.save(record(home,7,desktops:4,at:1000))
        try lib.save(record(office,3,desktops:2,at:2000))
        var prefs=MonitorPreferences(); prefs.setDisplayName("家里",for:home.key)
        let list=lib.screens(connectedKey:home.key,name:prefs.displayName)
        XCTAssertEqual(list.map(\.key),[home.key,office.key])
        XCTAssertEqual(list[0].name,"家里"); XCTAssertTrue(list[0].connected)
        XCTAssertEqual(list[0].windowCount,7); XCTAssertEqual(list[0].desktopCount,4)
        XCTAssertEqual(list[1].name,"LG UltraFine"); XCTAssertFalse(list[1].connected)
        // Nothing connected: newest first.
        XCTAssertEqual(lib.screens(connectedKey:nil,name:prefs.displayName).map(\.key),[office.key,home.key])
    }
    func testListIgnoresPreviousFilesHistoryAndUnreadableFiles() throws {
        try lib.save(record(home,2,at:1000)); try lib.save(record(home,3,at:2000))
        try Data("not json".utf8).write(to:lib.root.appendingPathComponent("monitor-1-2-3.json"))
        XCTAssertEqual(lib.screens(connectedKey:nil,name:\.name).map(\.key),[home.key])
    }
    func testEmptyLibraryHasNoScreens() {
        XCTAssertTrue(lib.screens(connectedKey:nil,name:\.name).isEmpty)
    }
    func testSavingArchivesPreviousVersionsUpToTheLimit() throws {
        for i in 1...6 { try lib.save(record(home,i,at:TimeInterval(i*1000))) }
        let v=lib.versions(home.key)
        XCTAssertEqual(v.count,4)                          // current + 3 archived (limit)
        XCTAssertTrue(v[0].isCurrent); XCTAssertEqual(v[0].windowCount,6)
        XCTAssertEqual(v.dropFirst().map(\.windowCount),[5,4,3])   // newest archived first, oldest dropped
    }
    func testPromoteSwapsVersionWithCurrentAndCanBeUndone() throws {
        try lib.save(record(home,2,at:1000)); try lib.save(record(home,5,at:2000))
        let older=lib.versions(home.key)[1]
        XCTAssertEqual(older.windowCount,2)
        let replaced=try XCTUnwrap(lib.promote(older.url,key:home.key))
        var v=lib.versions(home.key)
        XCTAssertEqual(v.map(\.windowCount),[2,5]); XCTAssertTrue(v[0].isCurrent)   // no duplicate entry
        try lib.promote(replaced,key:home.key)                                        // undo
        v=lib.versions(home.key)
        XCTAssertEqual(v.map(\.windowCount),[5,2])
    }
    func testPromoteRejectsFilesOutsideThatScreensHistory() throws {
        try lib.save(record(home,2,at:1000)); try lib.save(record(home,3,at:2000))
        try lib.save(record(office,1,at:1500)); try lib.save(record(office,4,at:2500))
        let officeOld=lib.versions(office.key)[1].url
        XCTAssertThrowsError(try lib.promote(officeOld,key:home.key))
        XCTAssertThrowsError(try lib.promote(lib.currentURL(home.key),key:home.key))
        XCTAssertEqual(lib.versions(home.key).map(\.windowCount),[3,2])
    }
    func testDeleteMovesEverythingToTrashAndUndoRestoresIt() throws {
        try lib.save(record(home,2,at:1000)); try lib.save(record(home,3,at:2000))
        let bin=try lib.delete(home.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath:lib.currentURL(home.key).path))
        XCTAssertTrue(lib.screens(connectedKey:nil,name:\.name).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:bin.appendingPathComponent("\(home.key).json").path))
        XCTAssertTrue(bin.path.hasPrefix(lib.trashDirectory.path))
        try lib.undoDelete(bin,key:home.key)
        XCTAssertEqual(lib.versions(home.key).map(\.windowCount),[3,2])
        XCTAssertFalse(FileManager.default.fileExists(atPath:bin.path))
    }
    func testUndoDeleteNeverOverwritesANewerSave() throws {
        try lib.save(record(home,2,at:1000))
        let bin=try lib.delete(home.key)
        try lib.save(record(home,9,at:3000))
        XCTAssertThrowsError(try lib.undoDelete(bin,key:home.key))
        XCTAssertEqual(lib.versions(home.key).first?.windowCount,9)
        XCTAssertTrue(FileManager.default.fileExists(atPath:bin.appendingPathComponent("\(home.key).json").path))   // still recoverable
    }
    func testLegacyPreviousFileBecomesFirstHistoryEntry() throws {
        // Written the old way: MonitorLayoutStore keeps exactly one .previous.json.
        try MonitorLayoutStore.save(record(home,2,at:1000),to:lib.currentURL(home.key))
        try MonitorLayoutStore.save(record(home,4,at:2000),to:lib.currentURL(home.key))
        XCTAssertEqual(lib.versions(home.key).map(\.windowCount),[4,2])
        try lib.save(record(home,6,at:3000))
        XCTAssertEqual(lib.versions(home.key).map(\.windowCount),[6,4,2])
    }
    func testRenameIsPerScreenAndClearable() {
        var prefs=MonitorPreferences()
        prefs.setDisplayName("  公司  ",for:office.key,seenName:office.name)
        XCTAssertEqual(prefs.displayName(office),"公司"); XCTAssertEqual(prefs.displayName(home),"DELL SE2416H")
        prefs.setDisplayName("",for:office.key)
        XCTAssertEqual(prefs.displayName(office),"LG UltraFine")
    }

    func testDefaultKeepsFiveHistoryVersions() throws {
        let five=ScreenLibrary(root:lib.root)
        XCTAssertEqual(five.historyLimit,5)
        for i in 1...9 { try five.save(record(home,i,at:TimeInterval(i*1000))) }
        XCTAssertEqual(five.versions(home.key).map(\.windowCount),[9,8,7,6,5,4])
    }
    func testLabelledHistoryVersionIsExemptFromPruning() throws {
        try lib.save(record(home,1,at:1000)); try lib.save(record(home,2,at:2000))
        let oldest=lib.versions(home.key)[1]
        try lib.labelVersion(oldest.url,key:home.key,label:" 演示前 ")
        for i in 3...8 { try lib.save(record(home,i,at:TimeInterval(i*1000))) }
        let v=lib.versions(home.key)
        XCTAssertEqual(v.map(\.windowCount),[8,7,6,5,1])          // 3 unlabelled + the labelled one
        XCTAssertEqual(v.last?.label,"演示前")
        try lib.labelVersion(oldest.url,key:home.key,label:"")      // clearing the label makes it prunable again
        XCTAssertEqual(lib.versions(home.key).map(\.windowCount),[8,7,6,5])
    }
    func testNamedLayoutsAreCopiesThatCanBeRenamedDeletedAndRestored() throws {
        try lib.save(record(home,4,at:1000))
        let code=try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"写代码",now:Date(timeIntervalSince1970:10))
        try lib.save(record(home,2,at:2000))
        let meeting=try lib.saveNamed(from:lib.versions(home.key)[0].url,key:home.key,name:"开会",now:Date(timeIntervalSince1970:20))
        XCTAssertEqual(lib.namedLayouts(home.key).map(\.name),["写代码","开会"])
        XCTAssertEqual(lib.namedLayouts(home.key).map(\.isActive),[false,true])
        XCTAssertThrowsError(try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"  "))
        try lib.renameNamed(code,key:home.key,name:"编程")
        XCTAssertEqual(lib.namedLayouts(home.key).first?.name,"编程")
        let bin=try lib.deleteNamed(meeting,key:home.key)
        XCTAssertEqual(lib.namedLayouts(home.key).map(\.name),["编程"])
        try lib.undoDeleteNamed(bin,key:home.key)
        XCTAssertEqual(lib.namedLayouts(home.key).map(\.name),["编程","开会"])
        // Many saves never prune named layouts.
        for i in 3...12 { try lib.save(record(home,i,at:TimeInterval(i*1000))) }
        XCTAssertEqual(lib.namedLayouts(home.key).count,2)
    }
    func testSwitchingBetweenNamedLayoutsAndUndo() throws {
        try lib.save(record(home,4,at:1000))
        let code=try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"写代码")
        try lib.save(record(home,2,at:2000))
        let meeting=try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"开会")
        let historyBefore=lib.versions(home.key).count
        // Current is already pinned as 开会, so switching doesn't add a duplicate history entry.
        let undo=try XCTUnwrap(lib.apply(code,key:home.key))
        XCTAssertEqual(undo.lastPathComponent,meeting.lastPathComponent)
        XCTAssertEqual(lib.versions(home.key).count,historyBefore)
        XCTAssertEqual(lib.versions(home.key).first?.windowCount,4)
        XCTAssertEqual(lib.namedLayouts(home.key).map(\.isActive),[true,false])
        XCTAssertNil(try lib.apply(code,key:home.key))               // already current: no-op
        try lib.apply(undo,key:home.key)
        XCTAssertEqual(lib.versions(home.key).first?.windowCount,2)
        // An unpinned current is archived when switching, and undo brings it back.
        try lib.save(record(home,7,at:3000))
        let back=try XCTUnwrap(lib.apply(code,key:home.key))
        XCTAssertTrue(back.path.contains("/history/"))
        try lib.apply(back,key:home.key)
        XCTAssertEqual(lib.versions(home.key).first?.windowCount,7)
        XCTAssertThrowsError(try lib.apply(lib.currentURL(office.key),key:home.key))
    }
    func testDeletingScreenAlsoTrashesAndRestoresNamedLayouts() throws {
        try lib.save(record(home,4,at:1000))
        try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"写代码")
        let bin=try lib.delete(home.key)
        XCTAssertTrue(lib.namedLayouts(home.key).isEmpty)
        try lib.undoDelete(bin,key:home.key)
        XCTAssertEqual(lib.namedLayouts(home.key).map(\.name),["写代码"])
    }

    func testHistoryRowsRememberWhichNamedLayoutTheyCameFrom() throws {
        try lib.save(record(home,4,at:1000))                                   // manual
        let code=try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"写代码")
        try lib.save(record(home,2,at:2000))
        let meeting=try lib.saveNamed(from:lib.currentURL(home.key),key:home.key,name:"开会")
        try lib.apply(code,key:home.key)                                       // current ← 写代码
        XCTAssertEqual(lib.versions(home.key).first?.originName,"写代码")
        try lib.apply(meeting,key:home.key)                                    // 写代码 copy pinned → not archived
        try lib.save(record(home,9,at:3000))                                   // archives the 开会 current, new one is manual
        var v=lib.versions(home.key)
        XCTAssertNil(v[0].originName)
        XCTAssertEqual(v[1].originName,"开会")
        XCTAssertNil(v.last?.originName)                                       // the first manual save
        // Renamed 版式 → current name; deleted 版式 → last-known name.
        try lib.renameNamed(meeting,key:home.key,name:"周会")
        XCTAssertEqual(lib.versions(home.key)[1].originName,"周会")
        try lib.deleteNamed(meeting,key:home.key)
        XCTAssertEqual(lib.versions(home.key)[1].originName,"开会")
        // Origin travels with a version when it is restored and back into history on undo.
        let back=try XCTUnwrap(lib.promote(lib.versions(home.key)[1].url,key:home.key))
        v=lib.versions(home.key)
        XCTAssertEqual(v[0].originName,"开会")
        XCTAssertNil(v.first{ $0.url==back }?.originName)
        try lib.promote(back,key:home.key)
        XCTAssertNil(lib.versions(home.key)[0].originName)
        XCTAssertEqual(lib.versions(home.key)[1].originName,"开会")
    }
    func testLegacyPreviousIsImportedOnlyOnce() throws {
        try MonitorLayoutStore.save(record(home,2,at:1000),to:lib.currentURL(home.key))
        try MonitorLayoutStore.save(record(home,4,at:2000),to:lib.currentURL(home.key))
        let old=lib.versions(home.key)[1]
        try lib.promote(old.url,key:home.key)                                  // history: [4]
        try lib.promote(lib.versions(home.key)[1].url,key:home.key)            // history: [2]
        XCTAssertEqual(lib.versions(home.key).map(\.windowCount),[4,2])
    }
}
