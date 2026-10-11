// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class FrameWriteTests: XCTestCase {
    func testGrowingWritesPositionThenSize() {
        XCTAssertEqual(FrameWritePlanner.order(current:Rect(0,0,800,600),target:Rect(100,100,1000,700)),[.position,.size])
        XCTAssertEqual(FrameWritePlanner.order(current:Rect(0,0,800,600),target:Rect(100,100,800,600)),[.position,.size])
    }
    func testShrinkingWritesSizeThenPosition() {
        XCTAssertEqual(FrameWritePlanner.order(current:Rect(-164,-1050,1920,1050),target:Rect(-124,-1010,1800,960)),[.size,.position])
        XCTAssertEqual(FrameWritePlanner.order(current:Rect(0,0,800,600),target:Rect(0,0,900,500)),[.size,.position],"any shrinking dimension goes size-first")
    }
    func testRetryReversesAndAlwaysEndsWithSize() {
        XCTAssertEqual(FrameWritePlanner.retry(after:[.size,.position]),[.position,.size])
        XCTAssertEqual(FrameWritePlanner.retry(after:[.position,.size]),[.size,.position,.size])
    }
    func testOutcome() {
        let target=Rect(-164,-1020,1880,1020)
        let xOnly=FrameWriteOutcome(observed:Rect(-164,-1050,1920,1050),target:target)
        XCTAssertFalse(xOnly.complete); XCTAssertFalse(xOnly.sizeApplied); XCTAssertFalse(xOnly.positionApplied)
        let full=FrameWriteOutcome(observed:Rect(-163,-1021,1879,1020),target:target)
        XCTAssertTrue(full.complete)
        XCTAssertEqual(FrameWriteOutcome(observed:Rect(-164,-1020,1920,1050),target:target),FrameWriteOutcome(positionApplied:true,sizeApplied:false))
    }
}
