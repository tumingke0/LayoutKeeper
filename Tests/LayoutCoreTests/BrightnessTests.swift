// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class BrightnessTests: XCTestCase {
    func testPackets() {
        XCTAssertEqual(DDCPacket.getVCP(0x10),[0x82,0x01,0x10,0x6E^0x51^0x82^0x01^0x10])
        let s=DDCPacket.setVCP(0x10,38)
        XCTAssertEqual(Array(s[0..<5]),[0x84,0x03,0x10,0x00,38])
        XCTAssertEqual(s[5],[0x84,0x03,0x10,0x00,38].reduce(0x6E^0x51,^))
        // Real reply captured from a DELL S2421HSX (brightness 38 / 100).
        let reply: [UInt8]=[0x6e,0x88,0x02,0x00,0x10,0x00,0x00,0x64,0x00,0x26,0xe6,0x00]
        XCTAssertEqual(DDCPacket.parseReply(reply,code:0x10)?.current,38)
        XCTAssertEqual(DDCPacket.parseReply(reply,code:0x10)?.max,100)
        XCTAssertNil(DDCPacket.parseReply(reply,code:0x62))
        var bad=reply; bad[9]=0x27
        XCTAssertNil(DDCPacket.parseReply(bad,code:0x10))
    }
    func testSteps() {
        XCTAssertEqual(BrightnessStep.coarse,0.05)
        XCTAssertEqual(BrightnessStep.next(0.50,up:true),0.55)
        XCTAssertEqual(BrightnessStep.next(0.50,up:false),0.45)
        XCTAssertEqual(BrightnessStep.next(0.51,up:true),0.55)
        XCTAssertEqual(BrightnessStep.next(0.38,up:true),0.40)
        XCTAssertEqual(BrightnessStep.next(0.38,up:false),0.35)
        XCTAssertEqual(BrightnessStep.next(0.97,up:true),1)
        XCTAssertEqual(BrightnessStep.next(0.03,up:false),0)
        // Volume keeps 3% per press.
        XCTAssertEqual(BrightnessStep.next(0.51,up:true,coarse:BrightnessStep.volumeCoarse),0.54)
        XCTAssertEqual(BrightnessStep.next(0.38,up:true,coarse:BrightnessStep.volumeCoarse),0.39)
        XCTAssertEqual(BrightnessStep.next(0.38,up:false,coarse:BrightnessStep.volumeCoarse),0.36)
        XCTAssertEqual(BrightnessStep.next(0.99,up:true),1)
        XCTAssertEqual(BrightnessStep.next(1,up:true),1)
        XCTAssertEqual(BrightnessStep.next(0,up:false),0)
        XCTAssertEqual(BrightnessStep.next(0.5,up:true,fine:true),0.51)
        XCTAssertEqual(BrightnessStep.toDDC(0.38,max:100),38)
        XCTAssertEqual(BrightnessStep.fromDDC(38,max:100),0.38,accuracy:1e-9)
    }
    func testLimiter() {
        var l=WriteLimiter(minInterval:0.06); let t=Date()
        XCTAssertEqual(l.delay(now:t),0)
        l.didWrite(at:t)
        XCTAssertEqual(l.delay(now:t.addingTimeInterval(0.02)),0.04,accuracy:1e-4)
        XCTAssertEqual(l.delay(now:t.addingTimeInterval(1)),0)
    }
    func testTakeover() {
        XCTAssertTrue(KeyTakeover.active(enabled:true,running:["com.apple.Safari"]))
        XCTAssertFalse(KeyTakeover.active(enabled:true,running:["pro.betterdisplay.BetterDisplay"]))
        XCTAssertFalse(KeyTakeover.active(enabled:false,running:[]))
        XCTAssertEqual(KeyTakeover.conflicts(running:["me.guillaumeb.MonitorControl","x"]),["MonitorControl"])
    }
    func testMediaKeys() {
        XCTAssertEqual(MediaKey.decode(data1:(2<<16)|(0x0A<<8))?.key,.brightnessUp)
        XCTAssertEqual(MediaKey.decode(data1:(2<<16)|(0x0A<<8))?.down,true)
        XCTAssertEqual(MediaKey.decode(data1:(3<<16)|(0x0B<<8))?.down,false)
        XCTAssertEqual(MediaKey.decode(data1:(7<<16)|(0x0A<<8))?.key,.mute)
        XCTAssertNil(MediaKey.decode(data1:(16<<16)|(0x0A<<8)))
        XCTAssertEqual(MediaKey.fromKeyCode(145),.brightnessDown)
    }
}
