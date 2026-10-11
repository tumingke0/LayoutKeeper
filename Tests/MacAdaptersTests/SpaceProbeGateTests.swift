// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
import SpaceProbe

final class SpaceProbeGateTests: XCTestCase {
    func testNativeGateMatchesProbeAndOSMajor() {
        var s=SPCrossSpaceSymbols(); SPProbeCrossSpaceSymbols(&s)
        let all=s.skyLightLoaded != 0 && s.moveOperationClass != 0 && s.moveOperationABI != 0 && s.membershipRead != 0 && s.managedDisplaySpaces != 0 && s.mainConnection != 0
        let modern=ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        XCTAssertEqual(SPControlledBridgeAvailable(),(all && modern) ? 1 : 0)
        if !modern { XCTAssertEqual(SPControlledBridgeAvailable(),0) }
    }
    func testMissingAXElementRejectsBeforePermissionOrWindowServerCalls() {
        var detail=[CChar](repeating:0,count:256)
        let result=SPDispatchVerifiedWindow(nil,0,0,0,"","","",0,0,"","",&detail,detail.count)
        XCTAssertEqual(result,-1);XCTAssertTrue(String(cString:detail).contains("Missing AX element"))
    }
}
