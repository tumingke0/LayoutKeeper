// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import MacAdapters
import LayoutCore

final class AppStateTests: XCTestCase {
    func testAuthorizationFollowsFreshSamplesIncludingRevocation() {
        var granted=false
        var calls=0
        let monitor=ControlAccessMonitor(query: { calls += 1; return granted })
        XCTAssertNil(monitor.state.trusted)
        XCTAssertFalse(monitor.state.canReadWindows)
        let first=Date(timeIntervalSince1970:10)
        XCTAssertEqual(monitor.check(at:first).trusted,false)
        XCTAssertEqual(monitor.state.checkedAt,first)
        granted=true
        XCTAssertTrue(monitor.check(at:Date(timeIntervalSince1970:12)).canReadWindows)
        granted=false
        XCTAssertFalse(monitor.check(at:Date(timeIntervalSince1970:14)).canReadWindows)
        XCTAssertEqual(calls,3)
    }

    func testUntrustedMessageDoesNotInventSignatureCause() {
        let state=ControlAccessState(trusted:false,checkedAt:Date())
        XCTAssertEqual(state.title,"系统控制权限：未授权")
        XCTAssertFalse(state.guidance.contains("编译"))
        XCTAssertFalse(state.guidance.contains("刷新一次授权"))
        XCTAssertTrue(state.guidance.contains("自动检查"))
    }

    func testSettingsOpenUsesControlPaneThenFallsBackWithoutPrompt() {
        var attempted=[URL]()
        let result=ControlSettings.open(using: { attempted.append($0); return attempted.count==2 })
        XCTAssertTrue(result)
        XCTAssertEqual(attempted.map(\.absoluteString),[
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "file:///System/Applications/System%20Settings.app/"
        ])
        XCTAssertFalse(ControlSettings.open(using: { _ in false }))
    }

    func testAccessibilityOpenerTriesNewPaneThenLegacyThenApp() {
        var attempted=[URL]()
        XCTAssertTrue(ControlSettings.openAccessibility(using: { attempted.append($0); return attempted.count==3 }))
        XCTAssertEqual(attempted.map(\.absoluteString),[
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "file:///System/Applications/System%20Settings.app/"
        ])
        var first=[URL]()
        XCTAssertTrue(ControlSettings.openAccessibility(using: { first.append($0); return true }))
        XCTAssertEqual(first.count,1)
    }
    func testRequestAccessibilityAsksWithPromptOption() {
        var seen: [String:Any]?
        XCTAssertFalse(ControlSettings.requestAccessibility(prompt: { seen=$0; return false }))
        XCTAssertEqual(seen?["AXTrustedCheckOptionPrompt"] as? Bool,true)
    }
    func testFixedEntryAndStorageDoNotDependOnProjectDirectory() {
        let home=URL(fileURLWithPath:"/tmp/lk-user",isDirectory:true)
        let fixed=AppInstallation.fixedBundleURL(home:home)
        XCTAssertEqual(fixed.path,"/tmp/lk-user/Applications/LayoutKeeper.app")
        XCTAssertEqual(AppInstallation.role(bundleURL:fixed,home:home),"固定安装入口")
        XCTAssertEqual(AppInstallation.role(bundleURL:home.appendingPathComponent("build-products/LayoutKeeper.app"),home:home),"测试候选")
        let support=home.appendingPathComponent("Library/Application Support",isDirectory:true)
        XCTAssertEqual(AppInstallation.layoutDirectory(bundleURL:fixed,applicationSupport:support).path,
                       "/tmp/lk-user/Library/Application Support/LayoutKeeper/Layouts")
        // Candidates in the project folder now share the same data folder; the project Layouts is only a migration source.
        let candidate=URL(fileURLWithPath:"/tmp/workspace/space-port/build-products/LayoutKeeper.app",isDirectory:true)
        XCTAssertEqual(AppInstallation.layoutDirectory(bundleURL:candidate,applicationSupport:support).path,
                       "/tmp/lk-user/Library/Application Support/LayoutKeeper/Layouts")
        XCTAssertEqual(AppInstallation.legacyDataSources(bundleURL:candidate,applicationSupport:support).map(\.root.path),
                       ["/tmp/lk-user/Library/Application Support/SpacePort","/tmp/workspace/space-port/Layouts"])
        XCTAssertEqual(AppInstallation.legacyDataSources(bundleURL:fixed,applicationSupport:support).map(\.root.path),
                       ["/tmp/lk-user/Library/Application Support/SpacePort"])
        let renamed=URL(fileURLWithPath:"/tmp/workspace/LayoutKeeper/build-products/LayoutKeeper.app",isDirectory:true)
        XCTAssertEqual(AppInstallation.legacyDataSources(bundleURL:renamed,applicationSupport:support).map(\.root.path),
                       ["/tmp/lk-user/Library/Application Support/SpacePort","/tmp/workspace/LayoutKeeper/Layouts"])
        let other=URL(fileURLWithPath:"/tmp/workspace/other/build-products/LayoutKeeper.app",isDirectory:true)
        XCTAssertEqual(AppInstallation.legacyDataSources(bundleURL:other,applicationSupport:support).count,1)
    }

    func testSaveFailureDoesNotTurnTimeoutOrDiskFailureIntoPermission() {
        let timeout=ExternalSaveMessage.failure(error:AXFailure(operation:"AXWindows",code:-25204),phase:.readWindows)
        XCTAssertTrue(timeout.contains("窗口读取"))
        XCTAssertFalse(timeout.contains("权限"))
        let disk=ExternalSaveMessage.failure(error:NSError(domain:NSCocoaErrorDomain,code:NSFileWriteNoPermissionError),phase:.writeRecord)
        XCTAssertTrue(disk.contains("布局文件"))
        XCTAssertFalse(disk.contains("系统控制"))
        XCTAssertTrue(ExternalSaveMessage.failure(error:LayoutError.permissionRequired,phase:.readWindows).contains("系统控制权限"))
    }
}
