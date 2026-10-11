// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class DataMigrationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("lk-migration-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    let monitor=MonitorIdentity(vendor:4268,model:53378,serial:7,name:"DELL")
    func record(_ title: String) -> MonitorLayoutRecord {
        MonitorLayoutRecord(monitor:monitor,profile:Profile(location:"DELL",windows:[
            SavedWindow(selector:WindowSelector(bundleID:"com.google.Chrome",title:title),displayRole:.external,desktopLabel:"组1",normalizedFrame:Rect(0.1,0.1,0.5,0.5),desktopIndex:1)]))
    }
    func write(_ text: String,_ url: URL,date: Date? = nil) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:url)
        if let date { try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:url.path) }
    }
    func saveRecord(_ r: MonitorLayoutRecord,_ url: URL,date: Date? = nil) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try MonitorLayoutStore.save(r,to:url)
        if let date { try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:url.path) }
    }

    func testCopiesEverythingVerifiesAndKeepsOldFolder() throws {
        let old=root.appendingPathComponent("SpacePort",isDirectory:true)
        let screens=old.appendingPathComponent("Layouts/screens",isDirectory:true)
        try saveRecord(record("A"),screens.appendingPathComponent("\(monitor.key).json"))
        try saveRecord(record("B"),screens.appendingPathComponent("\(monitor.key).previous.json"))
        try write("{\"report\":1}",old.appendingPathComponent("SelfTest/selftest-1.json"))
        try write("not a journal",old.appendingPathComponent("Layouts/transactions/x.json"))
        let target=root.appendingPathComponent("LayoutKeeper",isDirectory:true)
        let result=DataMigration.run(target:target,sources:[LegacyDataSource(root:old,layoutsSubpath:"Layouts")])
        XCTAssertEqual(result.status,.migrated)
        XCTAssertEqual(result.layouts,1)
        XCTAssertEqual(result.copiedFiles,4)
        let copied=try MonitorLayoutStore.load(from:target.appendingPathComponent("Layouts/screens/\(monitor.key).json"))
        XCTAssertEqual(copied.profile.windows.first?.selector.title,"A")
        XCTAssertEqual(try MonitorLayoutStore.load(from:target.appendingPathComponent("Layouts/screens/\(monitor.key).previous.json")).profile.windows.first?.selector.title,"B")
        XCTAssertTrue(FileManager.default.fileExists(atPath:target.appendingPathComponent("SelfTest/selftest-1.json").path))
        // Old folder untouched, marker written, no staging left behind.
        XCTAssertTrue(FileManager.default.fileExists(atPath:screens.appendingPathComponent("\(monitor.key).json").path))
        XCTAssertEqual(DataMigration.readMarker(in:target)?.status,.migrated)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:target.path).contains{$0.hasPrefix(".migration-staging")})
        XCTAssertEqual(DataMigration.run(target:target,sources:[LegacyDataSource(root:old,layoutsSubpath:"Layouts")]).status,.alreadyDone)
    }

    func testExistingLayoutsInNewFolderAreNeverOverwritten() throws {
        let old=root.appendingPathComponent("SpacePort",isDirectory:true)
        try saveRecord(record("old"),old.appendingPathComponent("Layouts/screens/\(monitor.key).json"))
        let target=root.appendingPathComponent("LayoutKeeper",isDirectory:true)
        try saveRecord(record("new"),target.appendingPathComponent("Layouts/screens/\(monitor.key).json"))
        let result=DataMigration.run(target:target,sources:[LegacyDataSource(root:old,layoutsSubpath:"Layouts")])
        XCTAssertEqual(result.status,.notNeeded)
        XCTAssertEqual(try MonitorLayoutStore.load(from:target.appendingPathComponent("Layouts/screens/\(monitor.key).json")).profile.windows.first?.selector.title,"new")
    }

    func testProjectLayoutsAreMergedAndNewerFileWins() throws {
        let support=root.appendingPathComponent("SpacePort",isDirectory:true)
        let project=root.appendingPathComponent("space-port/Layouts",isDirectory:true)
        let older=Date(timeIntervalSince1970:1_700_000_000),newer=Date(timeIntervalSince1970:1_800_000_000)
        try saveRecord(record("support-old"),support.appendingPathComponent("Layouts/screens/\(monitor.key).json"),date:older)
        try saveRecord(record("project-new"),project.appendingPathComponent("screens/\(monitor.key).json"),date:newer)
        try write("{}",support.appendingPathComponent("SelfTest/a.txt"))
        try write("{}",project.appendingPathComponent("demo/home.json"))
        let target=root.appendingPathComponent("LayoutKeeper",isDirectory:true)
        let result=DataMigration.run(target:target,sources:[LegacyDataSource(root:support,layoutsSubpath:"Layouts"),LegacyDataSource(root:project,layoutsSubpath:nil)])
        XCTAssertEqual(result.status,.migrated)
        XCTAssertEqual(result.sources.count,2)
        XCTAssertEqual(try MonitorLayoutStore.load(from:target.appendingPathComponent("Layouts/screens/\(monitor.key).json")).profile.windows.first?.selector.title,"project-new")
        XCTAssertTrue(FileManager.default.fileExists(atPath:target.appendingPathComponent("SelfTest/a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:target.appendingPathComponent("Layouts/demo/home.json").path))
        // Both legacy copies still exist.
        XCTAssertEqual(try MonitorLayoutStore.load(from:support.appendingPathComponent("Layouts/screens/\(monitor.key).json")).profile.windows.first?.selector.title,"support-old")
    }

    func testNoLegacyDataMeansNothingToDoAndNoMarker() {
        let target=root.appendingPathComponent("LayoutKeeper",isDirectory:true)
        let result=DataMigration.run(target:target,sources:[LegacyDataSource(root:root.appendingPathComponent("missing"),layoutsSubpath:"Layouts")])
        XCTAssertEqual(result.status,.notNeeded)
        XCTAssertNil(DataMigration.readMarker(in:target))
    }

    func testPreferencesCopyOnlyMissingUserKeys() {
        let copy=DefaultsMigration.keysToCopy(old:["autoRestoreMode":"auto","NSWindow Frame x":"1","AppleLanguages":["zh"],"shared":1],current:["shared":2])
        XCTAssertEqual(Set(copy.keys),["autoRestoreMode"])
    }
}
