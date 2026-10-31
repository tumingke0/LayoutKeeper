// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// 0.6.15: input source switching (VCP 0x60 / LG 0xF4) and monitor speaker volume (VCP 0x62 / 0x8D).
final class DDCInputPacketTests: XCTestCase {
    func testInputAndSpeakerPackets() {
        XCTAssertEqual(DDCPacket.setVCP(0x60,0x11),[0x84,0x03,0x60,0x00,0x11,0xC9])
        XCTAssertEqual(DDCPacket.setVCP(0xF4,0x90,subAddress:0x50),[0x84,0x03,0xF4,0x00,0x90,0xDD])
        XCTAssertEqual(DDCPacket.setVCP(DDCPacket.speakerVolume,30).last,0xC4)
        XCTAssertEqual(DDCPacket.setVCP(DDCPacket.audioMute,1).last,0x34)
        // Default sub-address is unchanged for brightness.
        XCTAssertEqual(DDCPacket.setVCP(0x10,38),DDCPacket.setVCP(0x10,38,subAddress:0x51))
    }
    func testSourceCommand() {
        let std=InputSource(id:"hdmi1",name:"HDMI 1",value:0x11)
        XCTAssertEqual(std.command.code,0x60); XCTAssertEqual(std.command.subAddress,0x51)
        let lg=InputSource(id:"x",name:"HDMI 1 (LG)",value:0x90,lgAlt:true)
        XCTAssertEqual(lg.command.code,0xF4); XCTAssertEqual(lg.command.subAddress,0x50)
    }
}

final class InputSourceTests: XCTestCase {
    func testParser() {
        XCTAssertEqual(InputValueParser.parse("17"),17)
        XCTAssertEqual(InputValueParser.parse(" 0x11 "),17)
        XCTAssertEqual(InputValueParser.parse("0X1b"),27)
        XCTAssertEqual(InputValueParser.parse("255"),255)
        for bad in ["","0","0x0","256","0x100","abc","0x","-1","17.5","000000017"] { XCTAssertNil(InputValueParser.parse(bad),bad) }
        XCTAssertEqual(InputValueParser.format(17),"0x11")
    }
    func testDefaults() {
        let d=InputSourceCatalog.defaults
        XCTAssertEqual(d.map(\.value),[0x0F,0x10,0x11,0x12,0x1B])
        XCTAssertTrue(d.allSatisfy{ $0.visible && !$0.lgAlt })
        XCTAssertEqual(Set(d.map(\.id)).count,d.count)
        XCTAssertFalse(d.contains{ $0.id.contains(".") })
    }
    func testStoreRoundTripAndReset() {
        var list=InputSourceCatalog.defaults
        list[0].visible=false; list[2].name="Console"
        list.append(InputSource(id:"c1",name:"LG USB-C",value:0xD2,lgAlt:true))
        var map=InputSourceStore.setting([:],key:"a",sources:list)
        let back=InputSourceStore.decode(InputSourceStore.encode(map))
        XCTAssertEqual(InputSourceStore.sources(back,key:"a"),list)
        XCTAssertEqual(InputSourceStore.sources(back,key:"other"),InputSourceCatalog.defaults)
        map=InputSourceStore.setting(map,key:"a",sources:InputSourceCatalog.defaults)
        XCTAssertNil(map["a"])
        XCTAssertEqual(InputSourceStore.decode(Data("junk".utf8)),[:])
        XCTAssertEqual(InputSourceStore.decode(nil),[:])
    }
    func testPolicy() {
        func d(builtIn: Bool=false,ddc: Bool=true,certain: Bool=true,only: Bool=false,confirmed: Bool=false) -> InputSwitchDecision {
            InputSwitchPolicy.decide(isBuiltIn:builtIn,ddcAvailable:ddc,mappingCertain:certain,isOnlyActiveScreen:only,confirmedBefore:confirmed)
        }
        if case .blocked = d(builtIn:true) {} else { XCTFail("built-in") }
        if case .blocked = d(ddc:false) {} else { XCTFail("no ddc") }
        XCTAssertEqual(d(certain:false),.blocked(lk("无法确认这台显示器对应的 DDC 通道")))
        XCTAssertEqual(d(only:true),.confirmStrong)
        XCTAssertEqual(d(only:true,confirmed:true),.confirmStrong)   // "don't ask again" never covers the only screen
        XCTAssertEqual(d(),.confirmOnce)
        XCTAssertEqual(d(confirmed:true),.go)
    }
}

final class InputMenuTests: XCTestCase {
    func testIDs() {
        let id=InputMenu.itemID(display:42,source:"hdmi1")
        XCTAssertEqual(InputMenu.parse(id)?.display,42); XCTAssertEqual(InputMenu.parse(id)?.source,"hdmi1")
        XCTAssertNil(InputMenu.parse(InputMenu.editID))
        XCTAssertNil(InputMenu.parse("input.x.hdmi1"))
        XCTAssertNil(InputMenu.parse("input.42."))
        XCTAssertNil(InputMenu.parse("layout.1"))
        XCTAssertEqual(InputMenu.sanitizedSourceID("a.b"),"a-b")
    }
    func testOneDisplayIsFlat() throws {
        var list=InputSourceCatalog.defaults; list[4].visible=false
        let item=try XCTUnwrap(InputMenu(displays:[.init(id:7,name:"Monitor",blocked:nil,sources:list)]).menuItem)
        XCTAssertEqual(item.kind,.submenu); XCTAssertEqual(item.id,"input")
        let actions=item.children.filter{ $0.kind == .action && $0.id != InputMenu.editID }
        XCTAssertEqual(actions.map(\.title),["DisplayPort 1","DisplayPort 2","HDMI 1","HDMI 2"])
        XCTAssertTrue(actions.allSatisfy{ $0.enabled && !$0.checked })   // never marks a "current" input
        XCTAssertEqual(item.children.last?.id,InputMenu.editID)
    }
    func testBlockedAndTwoDisplays() throws {
        let a=InputMenu.Display(id:1,name:"A",blocked:nil,sources:InputSourceCatalog.defaults)
        let b=InputMenu.Display(id:2,name:"B",blocked:"why",sources:InputSourceCatalog.defaults)
        let item=try XCTUnwrap(InputMenu(displays:[a,b]).menuItem)
        let subs=item.children.filter{ $0.kind == .submenu }
        XCTAssertEqual(subs.map(\.title),["A","B"])
        XCTAssertEqual(subs[1].reason,"why")
        XCTAssertTrue(subs[1].children.filter{ $0.kind == .action }.allSatisfy{ !$0.enabled })
        XCTAssertEqual(subs[1].children.first?.title,"why")
        XCTAssertTrue(subs[0].children.filter{ $0.kind == .action }.allSatisfy(\.enabled))
        XCTAssertNil(InputMenu(displays:[]).menuItem)
        let hidden=InputSourceCatalog.defaults.map{ s -> InputSource in var c=s; c.visible=false; return c }
        let none=try XCTUnwrap(InputMenu(displays:[.init(id:3,name:"C",blocked:nil,sources:hidden)]).menuItem)
        XCTAssertFalse(none.children.contains{ $0.kind == .action && $0.id != InputMenu.editID })
    }
    func testStatusMenuPlacement() {
        var s=MenuState()
        XCTAssertFalse(StatusMenuModel.build(s).contains{ $0.id == "input" })
        s.inputMenu=InputMenu(displays:[.init(id:1,name:"A",blocked:nil,sources:InputSourceCatalog.defaults)])
        let items=StatusMenuModel.build(s)
        let i=items.firstIndex{ $0.id == "input" }, sep=items.firstIndex{ $0.id == "sep1" }
        XCTAssertNotNil(i); XCTAssertNotNil(sep); XCTAssertLessThan(i!,sep!)
    }
}

final class MonitorAudioMatcherTests: XCTestCase {
    typealias C=MonitorAudioMatcher.Candidate
    let hdmi=MonitorAudioMatcher.transportHDMI, dp=MonitorAudioMatcher.transportDisplayPort
    func testSettableOrNonDisplayOutputNeverMatches() {
        let c=[C(id:1,name:"ACME VIEW 27Q",hasSpeakerVolume:true)]
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"ACME VIEW 27Q",transport:hdmi,volumeSettable:true,candidates:c,externalCount:1))
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"ACME VIEW 27Q",transport:0x75736220,volumeSettable:false,candidates:c,externalCount:1))   // 'usb '
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"ACME VIEW 27Q",transport:0,volumeSettable:false,candidates:c,externalCount:1))
    }
    func testNameMatch() {
        let c=[C(id:1,name:"ACME VIEW 27Q",hasSpeakerVolume:true),C(id:2,name:"CONTOSO 4K",hasSpeakerVolume:true)]
        XCTAssertEqual(MonitorAudioMatcher.match(deviceName:"CONTOSO 4K",transport:dp,volumeSettable:false,candidates:c,externalCount:2),2)
        XCTAssertEqual(MonitorAudioMatcher.match(deviceName:"acme view 27q (2)",transport:hdmi,volumeSettable:false,candidates:c,externalCount:2),1)
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"Other",transport:hdmi,volumeSettable:false,candidates:c,externalCount:2))
    }
    func testDigitsStillMatter() {
        // Different models must not collapse to the same key.
        XCTAssertNotEqual(MonitorAudioMatcher.normalized("ACME 27X1"),MonitorAudioMatcher.normalized("ACME 32X1"))
        XCTAssertEqual(MonitorAudioMatcher.normalized(" ACME 27X1 (3)"),MonitorAudioMatcher.normalized("acme 27x1"))
    }
    func testTwoSameModelsAreAmbiguous() {
        let c=[C(id:1,name:"ACME VIEW 27Q",hasSpeakerVolume:true),C(id:2,name:"ACME VIEW 27Q",hasSpeakerVolume:true)]
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"ACME VIEW 27Q",transport:hdmi,volumeSettable:false,candidates:c,externalCount:2))
        var m=c; m[1].overrideDevice="ACME VIEW 27Q"
        XCTAssertEqual(MonitorAudioMatcher.match(deviceName:"ACME VIEW 27Q",transport:hdmi,volumeSettable:false,candidates:m,externalCount:2),2)
    }
    func testManualOverrideWinsAndExcludes() {
        // Manual choice works even when the volume couldn't be read.
        let c=[C(id:1,name:"A",hasSpeakerVolume:false,overrideDevice:"Speakers X")]
        XCTAssertEqual(MonitorAudioMatcher.match(deviceName:"Speakers X",transport:hdmi,volumeSettable:false,candidates:c,externalCount:1),1)
        // A monitor assigned to another device is not picked automatically.
        let d=[C(id:1,name:"A",hasSpeakerVolume:true,overrideDevice:"Speakers X")]
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"A",transport:hdmi,volumeSettable:false,candidates:d,externalCount:1))
    }
    func testSingleMonitorFallback() {
        let c=[C(id:5,name:"Display",hasSpeakerVolume:true)]
        XCTAssertEqual(MonitorAudioMatcher.match(deviceName:"Something else",transport:hdmi,volumeSettable:false,candidates:c,externalCount:1),5)
        // Not when another external display (e.g. without DDC) could be the output.
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"Something else",transport:hdmi,volumeSettable:false,candidates:c,externalCount:2))
        // Not when the monitor has no readable speaker volume.
        let n=[C(id:5,name:"Display",hasSpeakerVolume:false)]
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"Something else",transport:hdmi,volumeSettable:false,candidates:n,externalCount:1))
        XCTAssertNil(MonitorAudioMatcher.match(deviceName:"Display",transport:hdmi,volumeSettable:false,candidates:n,externalCount:1))
    }
}

final class MonitorSpeakerRoutingTests: XCTestCase {
    func testRouting() {
        for key in [MediaKey.volumeUp,.volumeDown,.mute] {
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:true,outputVolumeSettable:false,outputMuteSettable:false,monitorSpeakerEnabled:true,speakerDisplay:9),.monitorSpeaker(9))
            // Feature off or no match: exactly the 0.6.9 behaviour.
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:true,outputVolumeSettable:false,outputMuteSettable:false,monitorSpeakerEnabled:false,speakerDisplay:9),.passThrough)
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:true,outputVolumeSettable:false,outputMuteSettable:false,monitorSpeakerEnabled:true,speakerDisplay:nil),.passThrough)
            // A settable output always stays on the system volume.
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:true,outputVolumeSettable:true,outputMuteSettable:true,monitorSpeakerEnabled:true,speakerDisplay:9),.systemOutput)
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:false,outputVolumeSettable:false,outputMuteSettable:false,monitorSpeakerEnabled:true,speakerDisplay:9),.passThrough)
        }
        // Mute settable but volume not: with a matched monitor all keys go to the monitor (one place for volume and mute).
        XCTAssertEqual(VolumeKeyRouting.route(.mute,enabled:true,outputVolumeSettable:false,outputMuteSettable:true,monitorSpeakerEnabled:true,speakerDisplay:9),.monitorSpeaker(9))
        XCTAssertEqual(VolumeKeyRouting.route(.mute,enabled:true,outputVolumeSettable:false,outputMuteSettable:true,monitorSpeakerEnabled:true,speakerDisplay:nil),.systemOutput)
        XCTAssertEqual(VolumeKeyRouting.route(.brightnessUp,enabled:true,outputVolumeSettable:false,outputMuteSettable:false,monitorSpeakerEnabled:true,speakerDisplay:9),.passThrough)
    }
}

final class SpeakerLevelTests: XCTestCase {
    func testSteps() {
        let s=SpeakerLevel(level:0.30)
        var (n,w)=s.press(.volumeUp,fine:false,hardwareMute:true)
        XCTAssertEqual(n.level,0.33,accuracy:1e-9); XCTAssertEqual(w,[.volume(0.33)])
        (n,w)=s.press(.volumeDown,fine:true,hardwareMute:true)
        XCTAssertEqual(n.level,0.29,accuracy:1e-9)
        (n,_)=SpeakerLevel(level:0.01).press(.volumeDown,fine:false,hardwareMute:true)
        XCTAssertEqual(n.level,0); XCTAssertFalse(n.muted)   // down to 0 is not mute
    }
    func testUnknownStartIsLow() {
        let (n,w)=SpeakerLevel(level:SpeakerLevel.unknownStart).press(.volumeUp,fine:false,hardwareMute:false)
        // Same 3% grid as the system volume: 10% → 12%.
        XCTAssertEqual(n.level,0.12,accuracy:1e-9); XCTAssertEqual(w,[.volume(0.12)])
        XCTAssertLessThanOrEqual(SpeakerLevel.unknownStart,0.10)
    }
    func testHardwareMute() {
        let s=SpeakerLevel(level:0.4)
        let (m,w1)=s.press(.mute,fine:false,hardwareMute:true)
        XCTAssertTrue(m.muted); XCTAssertEqual(m.level,0.4); XCTAssertEqual(w1,[.mute(true)])
        let (u,w2)=m.press(.mute,fine:false,hardwareMute:true)
        XCTAssertFalse(u.muted); XCTAssertEqual(w2,[.mute(false)])
        let (v,w3)=m.press(.volumeUp,fine:false,hardwareMute:true)
        XCTAssertFalse(v.muted); XCTAssertEqual(v.level,0.42,accuracy:1e-9); XCTAssertEqual(w3,[.mute(false),.volume(0.42)])
    }
    func testSoftMuteKeepsLevel() {
        let s=SpeakerLevel(level:0.4)
        let (m,w1)=s.press(.mute,fine:false,hardwareMute:false)
        XCTAssertTrue(m.muted); XCTAssertEqual(w1,[.volume(0)])
        let (u,w2)=m.press(.mute,fine:false,hardwareMute:false)
        XCTAssertFalse(u.muted); XCTAssertEqual(w2,[.volume(0.4)])
        let (d,w3)=m.press(.volumeDown,fine:false,hardwareMute:false)
        XCTAssertFalse(d.muted); XCTAssertEqual(d.level,0.39,accuracy:1e-9); XCTAssertEqual(w3,[.volume(0.39)])
    }
    func testMergeKeepsSoftMutedLevel() {
        let muted=SpeakerLevel(level:0.4,muted:true)
        XCTAssertEqual(SpeakerLevel.merged(existing:muted,readLevel:0,readMuted:nil,hardwareMute:false),muted)
        XCTAssertEqual(SpeakerLevel.merged(existing:muted,readLevel:0.2,readMuted:false,hardwareMute:true),SpeakerLevel(level:0.2,muted:false))
        XCTAssertEqual(SpeakerLevel.merged(existing:nil,readLevel:0.5,readMuted:true,hardwareMute:true),SpeakerLevel(level:0.5,muted:true))
        XCTAssertEqual(SpeakerLevel.merged(existing:SpeakerLevel(level:0.1),readLevel:0.6,readMuted:nil,hardwareMute:false),SpeakerLevel(level:0.6))
    }
}
