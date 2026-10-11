// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class MonitorLayoutTests: XCTestCase {
    func testSaveCoversEnumerableWindowsOnActiveAndInactiveExternalDesktops() throws {
        let backend=DemoBackend()
        backend.state.windows += [
            ObservedWindow(token:"first",selector:WindowSelector(bundleID:"fake.first",title:"甲"),frame:Rect(1300,100,400,400),spaceIDs:[72]),
            ObservedWindow(token:"second",selector:WindowSelector(bundleID:"fake.second",title:"乙"),frame:Rect(1800,100,400,400),spaceIDs:[73])]
        let (record,issues)=try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏"),displayToken:"simulated-company-monitor",snapshot:backend.state)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(Set(record.profile.windows.map(\.selector.title)),Set(["甲","乙"]))
        XCTAssertEqual(record.coverage?.ordinaryDesktopCount,2)
        XCTAssertEqual(record.coverage?.representedDesktopCount,2)
        XCTAssertEqual(record.coverage?.readableWindowCount,2)
        XCTAssertNotEqual(record.profile.windows[0].desktopLabel,record.profile.windows[1].desktopLabel)
    }
    func testCaptureStoresDesktopOrdinalNotSpaceIDs() throws {
        let backend=DemoBackend()
        backend.state.windows += [
            ObservedWindow(token:"first",selector:WindowSelector(bundleID:"fake.first",title:"甲"),frame:Rect(1300,100,400,400),spaceIDs:[72]),
            ObservedWindow(token:"second",selector:WindowSelector(bundleID:"fake.second",title:"乙"),frame:Rect(1800,100,400,400),spaceIDs:[73])]
        let (record,_)=try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏"),displayToken:"simulated-company-monitor",snapshot:backend.state)
        let byTitle=Dictionary(uniqueKeysWithValues:record.profile.windows.map{($0.selector.title,$0.desktopIndex)})
        XCTAssertEqual(byTitle["甲"],1); XCTAssertEqual(byTitle["乙"],2)
        let json=String(decoding:try JSONEncoder().encode(record),as:UTF8.self)
        XCTAssertFalse(json.contains("\"72\"") || json.contains(":72,") || json.contains(":73,") || json.contains("simulated-company-monitor"),"no Space IDs or display tokens in layout files")
        var dictionary=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record.profile.windows[0])) as! [String:Any]
        dictionary.removeValue(forKey:"desktopIndex")
        XCTAssertNil(try JSONDecoder().decode(SavedWindow.self,from:JSONSerialization.data(withJSONObject:dictionary)).desktopIndex,"pre-0.2.0 records still load")
    }
    func testOlderMonitorRecordWithoutCoverageStillLoads() throws {
        let backend=DemoBackend()
        backend.state.windows[0].spaceIDs=[72]
        let (record,_)=try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏"),displayToken:"simulated-company-monitor",snapshot:backend.state)
        var dictionary=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as! [String:Any]
        dictionary.removeValue(forKey:"coverage")
        let loaded=try JSONDecoder().decode(MonitorLayoutRecord.self,from:JSONSerialization.data(withJSONObject:dictionary))
        try loaded.validate(); XCTAssertNil(loaded.coverage)
        XCTAssertEqual(loaded.profile,record.profile)
    }
    func testIdentityUsesHardwareAndDoesNotChangeWithDisplayName() {
        let home=MonitorIdentity(vendor:10,model:20,serial:30,name:"家里的屏幕")
        XCTAssertEqual(home.key,MonitorIdentity(vendor:10,model:20,serial:30,name:"新名字").key)
        XCTAssertNotEqual(home.key,MonitorIdentity(vendor:10,model:20,serial:31,name:"公司").key)
        XCTAssertFalse(MonitorIdentity(vendor:10,model:20,serial:0,name:"未知序列号").identifiesDevice)
    }
    func testCaptureAutomaticallyGroupsOnlyExternalOrdinaryWindows() throws {
        let backend=DemoBackend()
        let selector=WindowSelector(bundleID:"fake.chat",title:"聊天")
        backend.state.windows.append(ObservedWindow(token:"chat",selector:selector,frame:Rect(1300,100,500,500),spaceIDs:[72]))
        backend.state.windows.append(ObservedWindow(token:"full",selector:WindowSelector(bundleID:"fake.full",title:"全屏"),frame:Rect(1300,0,800,900),spaceIDs:[73],fullScreen:true))
        let (record,issues)=try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:10,model:20,serial:30,name:"外屏"),displayToken:"simulated-company-monitor",snapshot:backend.state)
        XCTAssertEqual(record.profile.windows.map(\.selector),[selector])
        XCTAssertEqual(issues.count,1)
        let json=String(data:try JSONEncoder().encode(record),encoding:.utf8)!
        for forbidden in ["spaceID","simulated-company-monitor","windowID","runtimeDisplayToken"] { XCTAssertFalse(json.contains(forbidden)) }
        let roundTrip=try JSONDecoder().decode(MonitorLayoutRecord.self,from:JSONEncoder().encode(record))
        try roundTrip.validate(); XCTAssertEqual(roundTrip.profile,record.profile)
    }
    func testCaptureReportsExcludedReadableWindowsWithoutClaimingCompleteCoverage() throws {
        let backend=DemoBackend();backend.state.windows[0].spaceIDs=[72]
        backend.state.windows[0].minimized=true
        let (record,_)=try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:1,model:2,serial:3,name:"外屏"),displayToken:"simulated-company-monitor",snapshot:backend.state)
        let row=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as! [String:Any]
        let coverage=row["coverage"] as! [String:Any]
        XCTAssertEqual(coverage["excludedReadableWindowCount"] as? Int,1)
        XCTAssertTrue((coverage["scope"] as? String)?.contains("completeness not guaranteed") == true)
    }
    func testCaptureRejectsBuiltInDisplayAsExternalTarget() {
        let backend=DemoBackend()
        XCTAssertThrowsError(try ExternalLayoutCapture.capture(monitor:MonitorIdentity(vendor:10,model:20,serial:30,name:"内置"),displayToken:"simulated-panel",snapshot:backend.state))
    }
}
