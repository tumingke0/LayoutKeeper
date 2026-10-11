// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class OnboardingTests: XCTestCase {
    func testLaunchReason() {
        XCTAssertEqual(OnboardingPolicy.reasonAtLaunch(completed:false,trusted:true),.firstRun)
        XCTAssertEqual(OnboardingPolicy.reasonAtLaunch(completed:false,trusted:false),.firstRun)
        XCTAssertEqual(OnboardingPolicy.reasonAtLaunch(completed:true,trusted:false),.missingPermission)
        XCTAssertNil(OnboardingPolicy.reasonAtLaunch(completed:true,trusted:true))
    }
    func testFullFlowAutoAdvancesOnceWhenPermissionGranted() {
        var flow=OnboardingFlow(reason:.firstRun,trusted:false)
        XCTAssertEqual(flow.steps,[.permission,.launchAtLogin,.firstLayout])
        XCTAssertEqual(flow.step,.permission)
        XCTAssertEqual(flow.primaryTitle,"跳过这一步")
        XCTAssertFalse(flow.canGoBack)
        XCTAssertFalse(flow.observePermission(false))
        XCTAssertTrue(flow.observePermission(true),"granted while shown → auto-advance")
        XCTAssertFalse(flow.observePermission(true),"only once")
        XCTAssertEqual(flow.primaryTitle,"下一步")
        flow.advance()
        XCTAssertEqual(flow.step,.launchAtLogin)
        XCTAssertTrue(flow.canGoBack)
        XCTAssertFalse(flow.observePermission(true),"no auto-advance on later steps")
        flow.advance()
        XCTAssertEqual(flow.step,.firstLayout)
        XCTAssertEqual(flow.primaryTitle,"完成")
        XCTAssertEqual(flow.stepLabel,"第 3 步，共 3 步")
        flow.advance()
        XCTAssertTrue(flow.finished)
        XCTAssertTrue(flow.marksCompleted)
        XCTAssertFalse(flow.skipped)
        flow.advance(); flow.back()
        XCTAssertEqual(flow.step,.firstLayout,"no changes after finishing")
    }
    func testAlreadyTrustedShowsCheckWithoutAutoAdvance() {
        var flow=OnboardingFlow(reason:.reopened,trusted:true)
        XCTAssertTrue(flow.permissionGranted)
        XCTAssertFalse(flow.observePermission(true))
        XCTAssertEqual(flow.step,.permission)
        XCTAssertEqual(flow.primaryTitle,"下一步")
    }
    func testPermissionLostDuringFlowIsTracked() {
        var flow=OnboardingFlow(reason:.firstRun,trusted:true)
        flow.observePermission(false)
        XCTAssertFalse(flow.permissionGranted)
        XCTAssertTrue(flow.observePermission(true))
    }
    func testMissingPermissionFlowIsSingleStep() {
        var flow=OnboardingFlow(reason:.missingPermission,trusted:false)
        XCTAssertEqual(flow.steps,[.permission])
        XCTAssertTrue(flow.isLast)
        XCTAssertEqual(flow.primaryTitle,"稍后再说")
        XCTAssertTrue(flow.observePermission(true))
        XCTAssertEqual(flow.primaryTitle,"完成")
        flow.advance()
        XCTAssertTrue(flow.finished)
    }
    func testSkipFinishesAndMarksCompleted() {
        var flow=OnboardingFlow(reason:.firstRun,trusted:false)
        flow.skip()
        XCTAssertTrue(flow.finished); XCTAssertTrue(flow.skipped); XCTAssertTrue(flow.marksCompleted)
        XCTAssertFalse(flow.observePermission(true),"no auto-advance after skipping")
    }
    func testLaunchAtLoginStatus() {
        XCTAssertTrue(LaunchAtLoginStatus.enabled.isOn)
        XCTAssertTrue(LaunchAtLoginStatus.requiresApproval.isOn)
        XCTAssertFalse(LaunchAtLoginStatus.disabled.isOn)
        XCTAssertNil(LaunchAtLoginStatus.enabled.message)
        XCTAssertNotNil(LaunchAtLoginStatus.requiresApproval.message)
        XCTAssertEqual(LaunchAtLoginStatus.unavailable("x").message,"无法设置开机自启：x")
    }
    func testFirstLayoutReminder() {
        XCTAssertTrue(FirstLayoutReminder.shouldRemind(flag:true,monitorConnected:true,hasLayout:false,trusted:true))
        XCTAssertFalse(FirstLayoutReminder.shouldRemind(flag:false,monitorConnected:true,hasLayout:false,trusted:true))
        XCTAssertFalse(FirstLayoutReminder.shouldRemind(flag:true,monitorConnected:false,hasLayout:false,trusted:true))
        XCTAssertFalse(FirstLayoutReminder.shouldRemind(flag:true,monitorConnected:true,hasLayout:true,trusted:true))
        XCTAssertFalse(FirstLayoutReminder.shouldRemind(flag:true,monitorConnected:true,hasLayout:false,trusted:false))
    }
}
