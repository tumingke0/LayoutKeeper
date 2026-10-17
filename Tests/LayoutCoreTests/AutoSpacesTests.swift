// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class AutoSpacesTests: XCTestCase {
    let ord=[Space(id:1,displayToken:"B"),Space(id:2,displayToken:"E")]
    func testDefaults() {
        XCTAssertTrue(AutoSpaces.defaultEnabled)          // auto-add stays on for new installs
        XCTAssertFalse(AutoSpaces.removeDefaultEnabled)   // auto-remove is off: avoids a Mission Control flash on every plug/unplug
    }
    func testAddDisabledByDefaultAndGuards() {
        XCTAssertEqual(AutoSpaces.planAdd(enabled:false,needed:4,available:2,spaces:ord),.failure(BlockerError(.disabled)))
        XCTAssertEqual(AutoSpaces.planAdd(enabled:true,needed:2,available:2,spaces:ord),.failure(BlockerError(.nothingToDo)))
        XCTAssertEqual(AutoSpaces.planAdd(enabled:true,needed:4,available:2,spaces:ord),.success(2))
        let fs=ord+[Space(id:9,displayToken:"E",kind:.fullScreenOrSplit)]
        XCTAssertEqual(AutoSpaces.planAdd(enabled:true,needed:4,available:2,spaces:fs),.failure(BlockerError(.fullScreenActive)))
        XCTAssertEqual(AutoSpaces.planAdd(enabled:true,needed:20,available:1,spaces:ord),.failure(BlockerError(.tooMany(19))))
    }
    func testRemoveOnlyEmptyMigrated() {
        let before=SpaceCensus(external:[10,11,12,13],builtIn:[1,2],externalCount:1)
        let after=SpaceCensus(external:[],builtIn:[1,2,10,11,12,13],externalCount:0)
        let r=AutoSpaces.planRemove(enabled:true,before:before,after:after,occupied:[11],active:[12],spaces:[])
        XCTAssertEqual(r,.success([10,13]))   // never 1,2 (original), 11 (has windows), 12 (active)
        XCTAssertEqual(AutoSpaces.planRemove(enabled:false,before:before,after:after,occupied:[],active:[],spaces:[]),.failure(BlockerError(.disabled)))
        XCTAssertEqual(AutoSpaces.planRemove(enabled:true,before:before,after:after,occupied:[],active:[],spaces:[Space(id:5,displayToken:"B",kind:.fullScreenOrSplit)]),.failure(BlockerError(.fullScreenActive)))
    }
    func testRemoveKeepsOneSpace() {
        let before=SpaceCensus(external:[10,11],builtIn:[],externalCount:1)
        let after=SpaceCensus(external:[],builtIn:[10,11],externalCount:0)
        XCTAssertEqual(AutoSpaces.planRemove(enabled:true,before:before,after:after,occupied:[],active:[],spaces:[]),.success([10]))
    }
    func testRemoveCap() {
        let ids=Array(UInt64(10)...UInt64(20))
        let before=SpaceCensus(external:ids,builtIn:[1],externalCount:1)
        let after=SpaceCensus(external:[],builtIn:[1]+ids,externalCount:0)
        XCTAssertEqual(AutoSpaces.planRemove(enabled:true,before:before,after:after,occupied:[],active:[],spaces:[]),.failure(BlockerError(.tooMany(11))))
    }
    func testVerification() {
        XCTAssertTrue(AutoSpaces.verifyAdded(before:[1,2],after:[1,2,7]))
        XCTAssertFalse(AutoSpaces.verifyAdded(before:[1,2],after:[1,7,8]))
        XCTAssertFalse(AutoSpaces.verifyAdded(before:[1,2],after:[1,2]))
        XCTAssertTrue(AutoSpaces.verifyRemoved(7,before:[1,7,2],after:[1,2]))
        XCTAssertFalse(AutoSpaces.verifyRemoved(7,before:[1,7,2],after:[1,7]))
        XCTAssertEqual(AutoSpaces.buttonIndex(of:7,ordered:[1,7,2],buttonCount:3),1)
        XCTAssertNil(AutoSpaces.buttonIndex(of:7,ordered:[1,7,2],buttonCount:4))
    }
}
