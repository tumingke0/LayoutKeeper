// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import MacAdapters

/// The registry path cross-check used by `DDCService.servicesByDisplay` (made-up paths).
final class DDCPathTests: XCTestCase {
    func testPathComponentsDropsPlane() {
        XCTAssertEqual(DDCService.pathComponents("IOService:/Root/io@1/fb0"),["Root","io@1","fb0"])
    }
    func testSiblingLayoutTieIsAllowed() {
        let paths: [UInt32:[String]]=[1:["Root","io","dispA"],2:["Root","io","dispB"]]
        XCTAssertTrue(DDCService.pathAllows(["Root","io","dcpA","proxy"],1,paths))
        XCTAssertTrue(DDCService.pathAllows(["Root","io","dcpB","proxy"],2,paths))
    }
    func testProxyOnAnotherBranchIsRejected() {
        let paths: [UInt32:[String]]=[1:["Root","io","dispA"],2:["Root","io","dispB"]]
        XCTAssertFalse(DDCService.pathAllows(["Root","io","dispB","proxy"],1,paths))
        XCTAssertTrue(DDCService.pathAllows(["Root","io","dispB","proxy"],2,paths))
    }
    func testUnknownDisplayIsRejected() {
        XCTAssertFalse(DDCService.pathAllows(["Root"],3,[1:["Root"]]))
    }
}
