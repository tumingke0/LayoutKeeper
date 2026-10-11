// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class GuidedDemoTests: XCTestCase {
    func testSavedLayoutRestoresBothVisibleDemoWindowsAfterScatter() throws {
        let backend=GuidedDemoBackend(), before=backend.state.windows
        let profile=try backend.capture(location:"家")
        backend.scatter()
        XCTAssertNotEqual(before.map(\.frame),backend.state.windows.map(\.frame))
        let plan=try backend.plan(profile:profile)
        XCTAssertEqual(plan.entries.map(\.status),[.ready,.ready])
        let results=Restorer.execute(plan,windows:backend,spaces:backend,approved:true)
        XCTAssertEqual(results.map(\.outcome),[.verified,.verified])
        XCTAssertEqual(before,backend.state.windows)
    }
    func testHomeAndCompanyCaptureRetainDistinctGeometry() throws {
        let backend=GuidedDemoBackend()
        let home=try backend.capture(location:"家")
        backend.scatter()
        let company=try backend.capture(location:"公司")
        XCTAssertNotEqual(home.windows.map(\.normalizedFrame),company.windows.map(\.normalizedFrame))
        let encoded=String(data:try JSONEncoder().encode(home),encoding:.utf8)!
        XCTAssertFalse(encoded.contains("spaceID")); XCTAssertFalse(encoded.contains("demo-display"))
        let results=Restorer.execute(try backend.plan(profile:home),windows:backend,spaces:backend,approved:true)
        XCTAssertTrue(results.allSatisfy{$0.outcome == .verified})
        XCTAssertEqual(try backend.capture(location:"家"),home)
        XCTAssertEqual(company.location,"公司")
    }
    func testDemoCannotReportSuccessForAnUnchangedBackend() throws {
        let backend=GuidedDemoBackend(), profile=try backend.capture(location:"家")
        backend.scatter(); backend.pretendSuccess=true
        let results=Restorer.execute(try backend.plan(profile:profile),windows:backend,spaces:backend,approved:true)
        XCTAssertEqual(results.map(\.outcome),[.failed,.failed])
    }
}
