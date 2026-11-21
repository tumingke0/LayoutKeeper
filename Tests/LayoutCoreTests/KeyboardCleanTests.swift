// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class KeyboardCleanTests: XCTestCase {
    typealias F=KeyboardCleanFilter
    func testKeyboardEventsAreDropped() {
        for pointer in [false,true] {
            XCTAssertEqual(F.verdict(type:F.keyDown,keyCode:0,blockPointer:pointer),.dropCounted)
            XCTAssertEqual(F.verdict(type:F.keyDown,keyCode:0,autorepeat:true,blockPointer:pointer),.drop)
            XCTAssertEqual(F.verdict(type:F.keyUp,keyCode:0,blockPointer:pointer),.drop)
            XCTAssertEqual(F.verdict(type:F.flagsChanged,blockPointer:pointer),.drop)
            XCTAssertEqual(F.verdict(type:F.keyDown,keyCode:F.escapeKeyCode,blockPointer:pointer),.escapeDown)
            XCTAssertEqual(F.verdict(type:F.keyDown,keyCode:F.escapeKeyCode,autorepeat:true,blockPointer:pointer),.escapeDown)
            XCTAssertEqual(F.verdict(type:F.keyUp,keyCode:F.escapeKeyCode,blockPointer:pointer),.escapeUp)
            XCTAssertTrue(F.verdict(type:F.keyUp,keyCode:F.escapeKeyCode,blockPointer:pointer).drops)
        }
    }
    func testMediaKeysDroppedOtherSystemEventsPass() {
        XCTAssertEqual(F.verdict(type:F.systemDefined,subtype:8,mediaKeyDown:true,blockPointer:false),.dropCounted)
        XCTAssertEqual(F.verdict(type:F.systemDefined,subtype:8,mediaKeyDown:false,blockPointer:false),.drop)
        XCTAssertEqual(F.verdict(type:F.systemDefined,subtype:8,autorepeat:true,mediaKeyDown:true,blockPointer:false),.drop)
        for sub in [0,1,7,9] { XCTAssertEqual(F.verdict(type:F.systemDefined,subtype:sub,blockPointer:true),.pass) }
        let down=F.mediaKeyState(data1:(0 << 16) | (0x0A << 8))
        XCTAssertTrue(down.down); XCTAssertFalse(down.repeating)
        let rep=F.mediaKeyState(data1:(1 << 16) | (0x0A << 8) | 1)
        XCTAssertTrue(rep.down); XCTAssertTrue(rep.repeating)
        XCTAssertFalse(F.mediaKeyState(data1:(0x0B << 8)).down)
    }
    func testPointerEventsOnlyDroppedWhenAsked() {
        for type in F.pointerTypes {
            XCTAssertEqual(F.verdict(type:type,blockPointer:false),.pass,"type \(type)")
            XCTAssertEqual(F.verdict(type:type,blockPointer:true),.drop,"type \(type)")
        }
        XCTAssertEqual(F.verdict(type:F.mouseMoved,blockPointer:true),.pass)
        XCTAssertEqual(F.verdict(type:F.mouseMoved,blockPointer:false),.pass)
        XCTAssertFalse(F.pointerTypes.contains(F.mouseMoved))
        XCTAssertEqual(Set(F.tapTypes(blockPointer:false)),[10,11,12,14])
        XCTAssertTrue(Set(F.tapTypes(blockPointer:true)).isSuperset(of:[1,2,22,29]))
        XCTAssertFalse(F.tapTypes(blockPointer:true).contains(F.mouseMoved))
    }
    func testModifierPressCountsOnce() {
        let shift: UInt64=0x0002_0000, cmd: UInt64=0x0010_0000
        XCTAssertTrue(F.isModifierPress(old:0,new:shift))
        XCTAssertFalse(F.isModifierPress(old:shift,new:0))
        XCTAssertTrue(F.isModifierPress(old:shift,new:shift|cmd))
        XCTAssertFalse(F.isModifierPress(old:shift|cmd,new:shift))
        XCTAssertFalse(F.isModifierPress(old:0,new:0x100))  // device-dependent bits ignored
    }
    func testEscapeHold() {
        let t0=Date(timeIntervalSince1970:1000)
        var h=EscapeHold()
        XCTAssertEqual(h.progress(at:t0),0)
        h.escapeDown(at:t0)
        h.escapeDown(at:t0.addingTimeInterval(1))  // auto-repeat keeps the first start
        XCTAssertFalse(h.isComplete(at:t0.addingTimeInterval(2.9)))
        XCTAssertEqual(h.progress(at:t0.addingTimeInterval(1.5)),0.5,accuracy:0.0001)
        XCTAssertTrue(h.isComplete(at:t0.addingTimeInterval(3)))
        h.escapeUp()
        XCTAssertFalse(h.isComplete(at:t0.addingTimeInterval(10)))
        // Released at 2.9 s: nothing
        h.escapeDown(at:t0); h.escapeUp()
        XCTAssertEqual(h.progress(at:t0.addingTimeInterval(4)),0)
        // Another key in between starts over
        h.escapeDown(at:t0); h.otherKey(); h.escapeDown(at:t0.addingTimeInterval(2))
        XCTAssertFalse(h.isComplete(at:t0.addingTimeInterval(4.5)))
        XCTAssertTrue(h.isComplete(at:t0.addingTimeInterval(5)))
    }
    func testSessionTimingAndLimit() {
        let t0=Date(timeIntervalSince1970:1000)
        let s=KeyboardCleanSession(start:t0,settings:.defaults)
        XCTAssertEqual(s.remaining(at:t0),60)
        XCTAssertEqual(s.remaining(at:t0.addingTimeInterval(59.5)),0.5,accuracy:0.0001)
        XCTAssertFalse(s.isExpired(at:t0.addingTimeInterval(59.9)))
        XCTAssertTrue(s.isExpired(at:t0.addingTimeInterval(60)))
        // Woke from sleep long after the end: over at once
        XCTAssertTrue(s.isExpired(at:t0.addingTimeInterval(3600)))
        XCTAssertEqual(s.remaining(at:t0.addingTimeInterval(3600)),0)
        // Never longer than 5 minutes
        let long=KeyboardCleanSession(start:t0,duration:3600,blockPointer:false)
        XCTAssertEqual(long.endsAt.timeIntervalSince(t0),300)
        // Clock moved back: still bounded
        XCTAssertTrue(long.isExpired(at:t0.addingTimeInterval(-600)))
        XCTAssertFalse(long.isExpired(at:t0))
        XCTAssertEqual(KeyboardCleanSession.countdownText(60),"1:00")
        XCTAssertEqual(KeyboardCleanSession.countdownText(59.2),"1:00")
        XCTAssertEqual(KeyboardCleanSession.countdownText(9),"0:09")
        XCTAssertEqual(KeyboardCleanSession.countdownText(300),"5:00")
        XCTAssertEqual(KeyboardCleanSession.countdownText(-3),"0:00")
        XCTAssertEqual(KeyboardCleanDuration.allCases.map(\.rawValue),[30,60,120,300])
        XCTAssertLessThanOrEqual(KeyboardCleanDuration.allCases.map(\.seconds).max()!,KeyboardCleanDuration.maxSeconds)
        XCTAssertTrue(KeyboardCleanEndReason.tapLost.needsNotice)
        XCTAssertFalse(KeyboardCleanEndReason.done.needsNotice)
        XCTAssertFalse(KeyboardCleanEndReason.timeout.needsNotice)
    }
    func testSettingsDecodeWithDefaults() throws {
        let d=JSONDecoder()
        XCTAssertEqual(try d.decode(KeyboardCleanSettings.self,from:Data("{}".utf8)),.defaults)
        XCTAssertEqual(try d.decode(KeyboardCleanSettings.self,from:Data(#"{"duration":45,"blockPointer":true}"#.utf8)),
                       KeyboardCleanSettings(duration:.minute1,blockPointer:true))
        XCTAssertEqual(KeyboardCleanSettings.defaults,KeyboardCleanSettings(duration:.minute1,blockPointer:false))
        let s=KeyboardCleanSettings(duration:.minutes5,blockPointer:true)
        XCTAssertEqual(try d.decode(KeyboardCleanSettings.self,from:JSONEncoder().encode(s)),s)
    }
    func testMenuItemPlacementAndState() {
        var s=MenuState(); s.monitorName="公司"
        let ids=StatusMenuModel.build(s).map(\.id)
        let i=ids.firstIndex(of:"keyboardClean")!
        XCTAssertEqual(ids[i-1],"keepAwake"); XCTAssertEqual(ids[i+1],"sep2")
        let item={ (s: MenuState) in StatusMenuModel.build(s).first{ $0.id=="keyboardClean" }! }
        XCTAssertEqual(item(s).title,"清理键盘")
        XCTAssertTrue(item(s).enabled); XCTAssertNil(item(s).reason); XCTAssertNil(item(s).hotkey)
        s.trusted=false
        XCTAssertFalse(item(s).enabled); XCTAssertEqual(item(s).reason,"需要辅助功能权限")
        s.trusted=true; s.keyboardCleaning=true
        XCTAssertFalse(item(s).enabled)
        // Works without an external monitor too
        var none=MenuState(); none.monitorName=nil
        XCTAssertTrue(item(none).enabled)
    }
    func testEnglishStringsExist() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let table=NSDictionary(contentsOf:root.appendingPathComponent("Resources/en.lproj/Localizable.strings")) as? [String:String]
        XCTAssertNotNil(table)
        let keys=["清理键盘","键盘已锁住","可以擦了，触控板和鼠标照常能用。","可以擦了，键盘和触控板都已锁住。","%@ 后自动解锁","已挡住 %@ 次按键",
                  "完成","按住 Esc 3 秒也能解锁","按住 Esc 3 秒解锁","继续按住 Esc…","电源键和 Touch ID 锁不住，擦的时候避开。",
                  "有应用开着安全输入，部分按键可能漏过去。","系统停掉了按键拦截，键盘已提前解锁。",
                  "锁不住键盘。请到 系统设置 › 隐私与安全性 › 辅助功能，把 LayoutKeeper 关掉再打开。","锁定时长","30 秒","1 分钟","2 分钟","5 分钟",
                  "同时锁住触控板和鼠标点击","打开后光标还能动，但点不了「完成」，用 Esc 长按或等倒计时解锁。","需要辅助功能权限"]
        for k in keys {
            let en=table?[k]
            XCTAssertNotNil(en,"missing English for \(k)")
            XCTAssertFalse(en?.contains("—") ?? false,k)
        }
    }
}
