// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class CrossSpaceCapabilityTests: XCTestCase {
    func testSelfTestedBuild() {
        XCTAssertEqual(CrossSpaceGate.decide(major:27,minor:0,patch:0,build:"26A428",probe:.all),.selfTested(version:"27.0 (26A428)"))
    }
    func testOtherModernVersionsAreAllowedButMarkedUntested() {
        for (maj,min,build) in [(26,0,"25A354"),(26,4,"25E246"),(27,0,"26A5353q"),(27,1,"26B100"),(28,0,"27A1")] {
            let s=CrossSpaceGate.decide(major:maj,minor:min,patch:0,build:build,probe:.all)
            XCTAssertTrue(s.enabled); XCTAssertTrue(s.isUntested,"\(maj).\(min) \(build)")
        }
        XCTAssertEqual(CrossSpaceGate.decide(major:26,minor:1,patch:2,build:"25B9",probe:.all),.untested(version:"26.1.2 (25B9)"))
    }
    func testLegacyMacOSIsDisabledEvenIfSymbolsResolve() {
        for (maj,min) in [(14,0),(14,6),(15,0),(15,5)] {
            let s=CrossSpaceGate.decide(major:maj,minor:min,patch:0,build:"X",probe:.all)
            XCTAssertFalse(s.enabled); XCTAssertTrue(s.detail.contains("14.5"))
        }
    }
    func testMissingSymbolsDisableOnModernMacOS() {
        var p=CrossSpaceProbe.all; p.moveOperationClass=false
        var s=CrossSpaceGate.decide(major:27,minor:0,patch:0,build:"26A428",probe:p)
        XCTAssertFalse(s.enabled); XCTAssertTrue(s.detail.contains("SLSBridgedMoveWindowsToManagedSpaceOperation"))
        p = .all; p.moveOperationABI=false
        s=CrossSpaceGate.decide(major:26,minor:0,patch:0,build:"a",probe:p); XCTAssertFalse(s.enabled)
        p = .all; p.membershipRead=false
        s=CrossSpaceGate.decide(major:26,minor:0,patch:0,build:"a",probe:p); XCTAssertFalse(s.enabled,"no readback, no moves"); XCTAssertTrue(s.detail.contains("SLSCopySpacesForWindows"))
        XCTAssertFalse(CrossSpaceGate.decide(major:27,minor:0,patch:0,build:"26A428",probe:.none).enabled)
        XCTAssertEqual(CrossSpaceProbe.all.missing,[])
    }
}
