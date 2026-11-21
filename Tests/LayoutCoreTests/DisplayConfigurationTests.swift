// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import XCTest
@testable import LayoutCore

/// Display-configuration layouts (issue #2): the built-in-only configuration is a
/// first-class layout key ("builtin-only"), recorded and restored exactly like a
/// monitor layout, except its windows are the built-in display's windows.
final class DisplayConfigurationTests: XCTestCase {
    func testBuiltInOnlyIdentity() {
        let id=MonitorIdentity.builtInOnly
        XCTAssertEqual(id.key,"builtin-only")
        XCTAssertEqual(MonitorIdentity.builtInOnlyKey,"builtin-only")
        XCTAssertTrue(id.isBuiltInOnly)
        XCTAssertEqual(id.layoutRole,.builtIn)
        XCTAssertFalse(MonitorIdentity.sharedExternal.isBuiltInOnly)
        XCTAssertEqual(MonitorIdentity.sharedExternal.layoutRole,.external)
        XCTAssertEqual(MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏").layoutRole,.external)
        XCTAssertEqual(MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏").key,"monitor-1-2-3")
    }

    func testCaptureBuiltInOnlyRecordsBuiltInWindows() throws {
        let backend=DemoBackend()
        backend.state.windows += [
            ObservedWindow(token:"ext",selector:WindowSelector(bundleID:"fake.ext",title:"外屏窗口"),frame:Rect(1300,100,400,400),spaceIDs:[72])]
        let (record,issues)=try ExternalLayoutCapture.capture(monitor:.builtInOnly,displayToken:"simulated-panel",snapshot:backend.state)
        XCTAssertTrue(issues.isEmpty)
        // Only the built-in window is captured; the external one is ignored.
        XCTAssertEqual(record.profile.windows.count,1)
        XCTAssertEqual(record.profile.windows[0].selector.title,lk("LayoutKeeper 演示项目"))
        XCTAssertEqual(record.profile.windows[0].displayRole,.builtIn)
        XCTAssertEqual(record.profile.windows[0].desktopIndex,1)
        XCTAssertEqual(record.profile.windows[0].desktopID,71)
        XCTAssertEqual(record.monitor.key,"builtin-only")
        try record.validate()
    }

    func testCaptureBuiltInOnlyRejectsExternalTarget() {
        let backend=DemoBackend()
        // A real monitor may not capture the built-in display, and the built-in-only
        // identity may not capture an external display: the role comes from the monitor.
        XCTAssertThrowsError(try ExternalLayoutCapture.capture(monitor:.builtInOnly,displayToken:"simulated-company-monitor",snapshot:backend.state))
        XCTAssertThrowsError(try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏"),displayToken:"simulated-panel",snapshot:backend.state))
    }

    func testValidateRejectsMixedRoles() throws {
        let backend=DemoBackend()
        var (record,_)=try ExternalLayoutCapture.capture(monitor:.builtInOnly,displayToken:"simulated-panel",snapshot:backend.state)
        record.profile.windows[0].displayRole = .external
        XCTAssertThrowsError(try record.validate())
        var (ext,_)=try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏"),displayToken:"simulated-company-monitor",snapshot:backend.state)
        // External capture of the demo state has no external windows; plant one with the wrong role.
        ext.profile.windows=[SavedWindow(selector:WindowSelector(bundleID:"fake.x",title:"X"),displayRole:.builtIn,desktopLabel:"组",normalizedFrame:Rect(0.1,0.1,0.5,0.5),desktopIndex:1)]
        XCTAssertThrowsError(try ext.validate())
    }

    func testBuiltInOnlyLayoutRoundTripRestoresFrameAndDesktop() throws {
        let backend=DemoBackend()
        let panel="simulated-panel"
        backend.state.displays.removeAll{$0.token != panel}
        backend.state.spaces.removeAll{$0.displayToken != panel}
        backend.state.spaces.append(Space(id:74,displayToken:panel))
        backend.state.windows[0].processStartedAt=Date(timeIntervalSince1970:100)
        let original=backend.state.windows[0]
        let (record,issues)=try ExternalLayoutCapture.capture(monitor:.builtInOnly,displayToken:panel,snapshot:backend.state)
        XCTAssertTrue(issues.isEmpty)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let library=ScreenLibrary(root:root.appendingPathComponent("screens",isDirectory:true))
        try library.save(record)
        let saved=try MonitorLayoutStore.load(from:library.currentURL("builtin-only"))

        for desktop: UInt64 in [71,74] {
            backend.state.windows[0].frame=Rect(100,100,400,300)
            backend.state.windows[0].spaceIDs=[desktop]
            let preview=try QuickRestorePlanner.plan(record:saved,monitor:.builtInOnly,displayToken:panel,snapshot:backend.state,allowCrossSpace:true)
            XCTAssertEqual(preview.items.map(\.state),[.ready])
            let plan=QuickRestorePlanner.executionPlan(preview,autoOnly:false,fresh:backend.state).plan
            let report=ManualRestorer.execute(plan,windows:backend,spaces:backend,approved:true,persist:{_ in})
            XCTAssertEqual(report.results.map(\.outcome),[.verified])
            let restored=try XCTUnwrap(backend.readWindow(token:original.token))
            XCTAssertTrue(restored.frame.near(original.frame))
            XCTAssertEqual(restored.spaceIDs,original.spaceIDs)
        }
    }

    func testQuickRestoreRejectsBuiltInLayoutForExternalDisplay() throws {
        let backend=DemoBackend()
        let (record,_)=try ExternalLayoutCapture.capture(monitor:.builtInOnly,displayToken:"simulated-panel",snapshot:backend.state)
        XCTAssertThrowsError(try QuickRestorePlanner.plan(record:record,monitor:.builtInOnly,displayToken:"simulated-company-monitor",snapshot:backend.state,allowCrossSpace:true))
    }

    func testMonitorRestorePlannerPlansBuiltInLayout() throws {
        let saved=SavedWindow(selector:WindowSelector(bundleID:"demo.editor",title:lk("LayoutKeeper 演示项目")),displayRole:.builtIn,desktopLabel:"组甲",normalizedFrame:Rect(0.05,0.05,0.8,0.85),desktopIndex:1,desktopID:71)
        let record=MonitorLayoutRecord(monitor:.builtInOnly,profile:Profile(location:lk("仅内屏"),windows:[saved]))
        let backend=DemoBackend()
        let plan=try MonitorRestorePlanner.plan(record:record,monitor:.builtInOnly,displayToken:"simulated-panel",snapshot:backend.state,groupSpaces:["组甲":71],allowCrossSpace:true)
        XCTAssertEqual(plan.entries.count,1)
        XCTAssertEqual(plan.entries.first?.status,.ready)
        XCTAssertEqual(plan.entries.first?.targetSpace,71)
    }
}
