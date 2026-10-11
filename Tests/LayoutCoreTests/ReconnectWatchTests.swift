// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class ReconnectWatchTests: XCTestCase {
    let t0=Date(timeIntervalSince1970:1_000_000)
    func testLaunchDoesNotTrigger() {
        var watch=ReconnectWatch(initialMonitorKey:"m1")
        XCTAssertEqual(watch.evaluate(at:t0,fingerprint:"a",monitorKey:"m1",hasLayout:true,mode:.ask),.idle)
    }
    func testReplugTriggersOnlyAfterStableInterval() {
        var watch=ReconnectWatch(initialMonitorKey:"m1")
        watch.note(.screens,at:t0,fingerprint:"none")
        XCTAssertEqual(watch.evaluate(at:t0+3.1,fingerprint:"none",monitorKey:nil,hasLayout:false,mode:.ask),.settled,"unplug settles without trigger")
        watch.note(.screens,at:t0+10,fingerprint:"x")
        XCTAssertEqual(watch.evaluate(at:t0+11,fingerprint:"x",monitorKey:"m1",hasLayout:true,mode:.ask),.wait(until:t0+13))
        watch.note(.screens,at:t0+12,fingerprint:"y")
        XCTAssertEqual(watch.evaluate(at:t0+13,fingerprint:"y",monitorKey:"m1",hasLayout:true,mode:.ask),.wait(until:t0+15),"new event restarts debounce")
        XCTAssertEqual(watch.evaluate(at:t0+15,fingerprint:"y",monitorKey:"m1",hasLayout:true,mode:.ask),.trigger(monitorKey:"m1"))
        XCTAssertEqual(watch.evaluate(at:t0+20,fingerprint:"y",monitorKey:"m1",hasLayout:true,mode:.ask),.idle,"fires once")
    }
    func testFingerprintChangeWithoutEventRestartsDebounce() {
        var watch=ReconnectWatch(initialMonitorKey:nil)
        watch.note(.screens,at:t0,fingerprint:"a")
        XCTAssertEqual(watch.evaluate(at:t0+3,fingerprint:"b",monitorKey:"m1",hasLayout:true,mode:.auto),.wait(until:t0+6))
        XCTAssertEqual(watch.evaluate(at:t0+6,fingerprint:"b",monitorKey:"m1",hasLayout:true,mode:.auto),.trigger(monitorKey:"m1"))
    }
    func testResolutionChangeOnSameMonitorDoesNotTrigger() {
        var watch=ReconnectWatch(initialMonitorKey:"m1")
        watch.note(.screens,at:t0,fingerprint:"scaled")
        XCTAssertEqual(watch.evaluate(at:t0+3,fingerprint:"scaled",monitorKey:"m1",hasLayout:true,mode:.ask),.settled)
    }
    func testWakeWithSameMonitorTriggers() {
        var watch=ReconnectWatch(initialMonitorKey:"m1")
        watch.note(.wake,at:t0,fingerprint:"a")
        XCTAssertEqual(watch.evaluate(at:t0+3,fingerprint:"a",monitorKey:"m1",hasLayout:true,mode:.ask),.trigger(monitorKey:"m1"))
    }
    func testNoLayoutOrOffModeOrNoMonitorDoesNotTriggerButUpdatesBaseline() {
        var watch=ReconnectWatch(initialMonitorKey:nil)
        watch.note(.screens,at:t0,fingerprint:"a")
        XCTAssertEqual(watch.evaluate(at:t0+3,fingerprint:"a",monitorKey:"m2",hasLayout:false,mode:.ask),.settled)
        XCTAssertEqual(watch.lastStableKey,"m2")
        watch.note(.wake,at:t0+10,fingerprint:"a")
        XCTAssertEqual(watch.evaluate(at:t0+13,fingerprint:"a",monitorKey:"m2",hasLayout:true,mode:.off),.settled)
        watch.note(.wake,at:t0+20,fingerprint:"a")
        XCTAssertEqual(watch.evaluate(at:t0+23,fingerprint:"a",monitorKey:nil,hasLayout:true,mode:.ask),.settled)
    }
    func testSwitchingToDifferentMonitorTriggersForNewKey() {
        var watch=ReconnectWatch(initialMonitorKey:"home")
        watch.note(.screens,at:t0,fingerprint:"office")
        XCTAssertEqual(watch.evaluate(at:t0+3,fingerprint:"office",monitorKey:"office",hasLayout:true,mode:.ask),.trigger(monitorKey:"office"))
    }
    func testDefaultModeIsAsk() { XCTAssertEqual(AutoRestoreMode.defaultMode,.ask) }
}
