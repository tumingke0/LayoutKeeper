// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import MacAdapters

final class RemoteTokenTests: XCTestCase {
    func testTokenLayoutIsTwentyLittleEndianBytes() {
        let bytes=RemoteElementToken.bytes(pid:0x0102_0304,elementID:0x1122_3344_5566_7788)
        XCTAssertEqual(bytes.count,20)
        XCTAssertEqual(Array(bytes[0..<4]),[0x04,0x03,0x02,0x01])
        XCTAssertEqual(Array(bytes[4..<8]),[0,0,0,0])
        XCTAssertEqual(Array(bytes[8..<12]),[0x6f,0x63,0x6f,0x63])
        XCTAssertEqual(Array(bytes[12..<20]),[0x88,0x77,0x66,0x55,0x44,0x33,0x22,0x11])
        XCTAssertEqual(RemoteElementToken.elementIDOffset,12)
    }
    func testSearchNeverTargetsOwnProcessOrRunsWithoutWantedWindows() {
        let locator=RemoteWindowLocator()
        let own=locator.search(pid:getpid(),processKey:"self",wanted:[1],timeBudget:1,elementCap:10,deadline:nil){_ in 1}
        XCTAssertEqual(own.inspected,0);XCTAssertEqual(own.unresolved,[1]);XCTAssertTrue(own.found.isEmpty)
        let none=locator.search(pid:1,processKey:"x",wanted:[],timeBudget:1,elementCap:10,deadline:nil){_ in 1}
        XCTAssertEqual(none.inspected,0);XCTAssertEqual(none.stop,.nothingWanted)
    }
    func testExpiredDeadlineStopsBeforeInspecting() {
        let locator=RemoteWindowLocator()
        guard locator.isAvailable else {return}
        // pid 1 (launchd) never answers AX; the deadline is already in the past so nothing is sent.
        let result=locator.search(pid:1,processKey:"launchd",wanted:[42],timeBudget:1,elementCap:1000,deadline:0){_ in nil}
        XCTAssertEqual(result.inspected,0);XCTAssertEqual(result.unresolved,[42]);XCTAssertEqual(result.stop,.deadline)
    }
    func testMissingPrivateSymbolDegradesToUnknownWindows() {
        let locator=RemoteWindowLocator(resolveSymbol:false)
        XCTAssertFalse(locator.isAvailable)
        let result=locator.search(pid:1,processKey:"x",wanted:[7,8],timeBudget:1,elementCap:10,deadline:nil){_ in 7}
        XCTAssertEqual(result.stop,.unavailable); XCTAssertEqual(result.inspected,0)
        XCTAssertEqual(result.unresolved,[7,8],"windows stay unresolved (reported as unknown), never treated as closed"); XCTAssertTrue(result.found.isEmpty)
    }
}
