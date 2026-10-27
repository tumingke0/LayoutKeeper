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

    func testBuiltInBrightnessSyncInitialBaselineDoesNotJumpExternals() {
        XCTAssertEqual(DisplayControlPrefs.syncWithBuiltIn,"displayControl.syncWithBuiltIn")
        let r=BuiltInBrightnessSync.evaluate(
            enabled:true,
            clamshell:false,
            previousBuiltIn:nil,
            currentBuiltIn:0.70,
            externalBrightnesses:[(id:2,brightness:0.50),(id:3,brightness:0.80)]
        )
        XCTAssertEqual(r.baseline ?? -1,0.70,accuracy:1e-6)
        XCTAssertTrue(r.updates.isEmpty)
    }

    func testBuiltInBrightnessSyncGradualDriftAccumulatesWithoutLosingSteps() {
        // Starts at built-in 0.70, external 0.50.
        // Drift by -0.008 three times: -0.008 (0.692), -0.016 (0.684), -0.024 (0.676 >= 0.02 threshold).
        var base: Double?=0.70
        var ext=0.50

        let step1=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:false,previousBuiltIn:base,currentBuiltIn:0.692,
            externalBrightnesses:[(id:10,brightness:ext)]
        )
        XCTAssertEqual(step1.baseline ?? -1,0.70,accuracy:1e-6,"Baseline must stay anchored at 0.70 until threshold is reached")
        XCTAssertTrue(step1.updates.isEmpty)
        base=step1.baseline

        let step2=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:false,previousBuiltIn:base,currentBuiltIn:0.684,
            externalBrightnesses:[(id:10,brightness:ext)]
        )
        XCTAssertEqual(step2.baseline ?? -1,0.70,accuracy:1e-6,"Baseline still anchored at 0.70 at -1.6% drift")
        XCTAssertTrue(step2.updates.isEmpty)
        base=step2.baseline

        let step3=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:false,previousBuiltIn:base,currentBuiltIn:0.676,
            externalBrightnesses:[(id:10,brightness:ext)]
        )
        XCTAssertEqual(step3.baseline ?? -1,0.676,accuracy:1e-6,"Baseline advances once cumulative drift reaches -2.4%")
        XCTAssertEqual(step3.updates.count,1)
        XCTAssertEqual(step3.updates.first?.id,10)
        XCTAssertEqual(step3.updates.first?.newBrightness ?? -1,0.476,accuracy:1e-6)
        ext=step3.updates[0].newBrightness
        base=step3.updates.isEmpty ? base : step3.baseline
        XCTAssertEqual(ext,0.476,accuracy:1e-6)
    }

    func testBuiltInBrightnessSyncPreservesRelativeOffsetAndClampsBounds() {
        // Built-in drops from 0.70 to 0.40 (-0.30).
        // External A: 0.50 -> 0.20; External B: 0.80 -> 0.50; External C: 0.20 -> clamped to 0.0; External D: already 0.0 -> no redundant write.
        let down=BuiltInBrightnessSync.evaluate(
            enabled:true,
            clamshell:false,
            previousBuiltIn:0.70,
            currentBuiltIn:0.40,
            externalBrightnesses:[
                (id:1,brightness:0.50),
                (id:2,brightness:0.80),
                (id:3,brightness:0.20),
                (id:4,brightness:0.00),
            ]
        )
        XCTAssertEqual(down.baseline ?? -1,0.40,accuracy:1e-6)
        XCTAssertEqual(down.updates.map(\.id),[1,2,3])
        XCTAssertEqual(down.updates[0].newBrightness,0.20,accuracy:1e-6)
        XCTAssertEqual(down.updates[1].newBrightness,0.50,accuracy:1e-6)
        XCTAssertEqual(down.updates[2].newBrightness,0.00,accuracy:1e-6)

        // Built-in rises from 0.40 to 0.90 (+0.50).
        // External A: 0.20 -> 0.70; External B: 0.65 -> clamped to 1.0; External E: already 1.0 -> no redundant write.
        let up=BuiltInBrightnessSync.evaluate(
            enabled:true,
            clamshell:false,
            previousBuiltIn:down.baseline,
            currentBuiltIn:0.90,
            externalBrightnesses:[
                (id:1,brightness:0.20),
                (id:2,brightness:0.65),
                (id:5,brightness:1.00),
            ]
        )
        XCTAssertEqual(up.baseline ?? -1,0.90,accuracy:1e-6)
        XCTAssertEqual(up.updates.map(\.id),[1,2])
        XCTAssertEqual(up.updates[0].newBrightness,0.70,accuracy:1e-6)
        XCTAssertEqual(up.updates[1].newBrightness,1.00,accuracy:1e-6)
    }

    func testBuiltInBrightnessSyncClamshellAndDisabledResetBaselineAndReestablishCleanly() {
        // Disabled -> nil baseline, no updates
        let off=BuiltInBrightnessSync.evaluate(
            enabled:false,clamshell:false,previousBuiltIn:0.70,currentBuiltIn:0.30,
            externalBrightnesses:[(id:1,brightness:0.50)]
        )
        XCTAssertNil(off.baseline)
        XCTAssertTrue(off.updates.isEmpty)

        // Lid closed (clamshell = true) -> nil baseline, no updates even if built-in reports 0.0
        let closed=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:true,previousBuiltIn:0.70,currentBuiltIn:0.0,
            externalBrightnesses:[(id:1,brightness:0.50)]
        )
        XCTAssertNil(closed.baseline)
        XCTAssertTrue(closed.updates.isEmpty)

        // Missing built-in display -> nil baseline, no updates
        let noBuiltIn=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:false,previousBuiltIn:0.70,currentBuiltIn:nil,
            externalBrightnesses:[(id:1,brightness:0.50)]
        )
        XCTAssertNil(noBuiltIn.baseline)
        XCTAssertTrue(noBuiltIn.updates.isEmpty)

        // Lid reopened: first read with previousBuiltIn == nil only establishes new baseline (0.60), no jump on external (still 0.50)
        let reopened=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:false,previousBuiltIn:closed.baseline,currentBuiltIn:0.60,
            externalBrightnesses:[(id:1,brightness:0.50)]
        )
        XCTAssertEqual(reopened.baseline ?? -1,0.60,accuracy:1e-6)
        XCTAssertTrue(reopened.updates.isEmpty)

        // Subsequent ambient change from 0.60 to 0.55 (-0.05) propagates -0.05 to external (0.50 -> 0.45)
        let next=BuiltInBrightnessSync.evaluate(
            enabled:true,clamshell:false,previousBuiltIn:reopened.baseline,currentBuiltIn:0.55,
            externalBrightnesses:[(id:1,brightness:0.50)]
        )
        XCTAssertEqual(next.baseline ?? -1,0.55,accuracy:1e-6)
        XCTAssertEqual(next.updates.count,1)
        XCTAssertEqual(next.updates[0].newBrightness,0.45,accuracy:1e-6)
    }
}
