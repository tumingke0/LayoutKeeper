// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class StatusMenuModelTests: XCTestCase {
    var cal: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone.current; return c }
    func state() -> MenuState {
        var s=MenuState()
        s.now=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:10,minute:0))!
        s.monitorName="公司"; s.windowCount=7; s.savedAt=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:9,minute:42))!
        return s
    }
    func ids(_ items: [MenuItemModel]) -> [String] { items.map(\.id) }
    func item(_ items: [MenuItemModel],_ id: String) -> MenuItemModel? { items.first{$0.id==id} }

    func testNormalOrderShortcutsAndStatusLine() {
        var s=state(); s.canUndo=true
        let items=StatusMenuModel.build(s)
        XCTAssertEqual(ids(items),["status","save","restore","undo","sep1","mode","pause","sep2","open","settings","quit"])
        XCTAssertTrue(item(items,"status")!.title.hasPrefix("公司 · 7 个窗口 · "))
        XCTAssertTrue(item(items,"status")!.title.hasSuffix("09:42"))
        XCTAssertFalse(item(items,"status")!.enabled)
        XCTAssertEqual(item(items,"save")?.shortcutText,"⌃⌥⌘S")
        XCTAssertEqual(item(items,"restore")?.shortcutText,"⌃⌥⌘R")
        XCTAssertEqual(item(items,"undo")?.shortcutText,"⌃⌥⌘Z")
        XCTAssertEqual(item(items,"settings")?.shortcutText,"⌘,")
        XCTAssertEqual(item(items,"quit")?.title,"退出 LayoutKeeper")
    }
    func testOptionSwapsRestoreAndSettings() {
        var s=state(); s.optionHeld=true
        let items=StatusMenuModel.build(s)
        XCTAssertNil(item(items,"restore")); XCTAssertEqual(item(items,"previewRestore")?.title,"预览后恢复…")
        XCTAssertNil(item(items,"settings")); XCTAssertEqual(item(items,"diagnostics")?.title,"诊断…")
        XCTAssertNil(item(items,"undo"))
    }
    func testDisabledItemsCarryShortReasons() {
        var s=state(); s.monitorName=nil
        var items=StatusMenuModel.build(s)
        XCTAssertEqual(item(items,"status")?.title,"未连接外接屏")
        XCTAssertEqual(item(items,"save")?.reason,"未连接外接屏"); XCTAssertFalse(item(items,"save")!.enabled)
        s=state(); s.savedAt=nil; s.windowCount=nil
        items=StatusMenuModel.build(s)
        XCTAssertEqual(item(items,"status")?.title,"公司 · 尚未保存")
        XCTAssertTrue(item(items,"save")!.enabled)
        XCTAssertEqual(item(items,"restore")?.reason,"尚未保存布局")
        s=state(); s.trusted=false
        items=StatusMenuModel.build(s)
        XCTAssertEqual(item(items,"save")?.reason,"需要辅助功能权限"); XCTAssertEqual(item(items,"restore")?.reason,"需要辅助功能权限")
    }
    func testHotkeysOffHideShortcuts() {
        var s=state(); s.hotkeys.enabled=false
        XCTAssertNil(item(StatusMenuModel.build(s),"save")?.shortcutText)
    }
    func testModeSubmenuShowsRememberedChoiceAndPause() {
        var s=state(); s.monitorChoice = .auto; s.pausedUntil=s.now.addingTimeInterval(1800)
        let items=StatusMenuModel.build(s)
        let modes=item(items,"mode")!.children
        XCTAssertEqual(modes.filter(\.checked).map(\.id),["mode.ask"])
        XCTAssertEqual(item(modes,"mode.override")?.title,"公司：自动恢复（已记住）")
        XCTAssertNotNil(item(modes,"mode.forget"))
        let pause=item(items,"pause")!
        XCTAssertTrue(pause.title.contains("已暂停"))
        XCTAssertEqual(ids(pause.children),["resume"])
        s.pausedUntil=nil
        XCTAssertEqual(ids(item(StatusMenuModel.build(s),"pause")!.children),["pause.oneHour","pause.untilTomorrow"])
    }
}

final class HotkeyRegistrarTests: XCTestCase {
    func testAllRegisteredWithDefaults() {
        var attempted=[HotkeyAction]()
        let status=HotkeyRegistrar.register(.defaults) { action,key in attempted.append(action); XCTAssertEqual(key.modifiers.carbonFlags,0x1900); return true }
        XCTAssertEqual(attempted,[.save,.restore,.undo])
        XCTAssertEqual(Set(status.values),[.active])
    }
    func testSystemRefusalIsReportedAsConflictOthersStillRegister() {
        let status=HotkeyRegistrar.register(.defaults) { action,_ in action != .restore }
        XCTAssertEqual(status[.save],.active)
        XCTAssertEqual(status[.undo],.active)
        guard case .conflict(let message)? = status[.restore] else { return XCTFail() }
        XCTAssertTrue(message.contains("⌃⌥⌘R"))
    }
    func testDuplicateAndInvalidNeverReachTheSystem() {
        var settings=HotkeySettings.defaults
        settings.keys[.undo]=settings.keys[.save]
        settings.keys[.restore]=Hotkey(keyCode:15,modifiers:[.shift])
        var attempts=0
        let status=HotkeyRegistrar.register(settings) { _,_ in attempts+=1; return true }
        XCTAssertEqual(attempts,1)
        XCTAssertEqual(status[.undo],.conflict("与「保存当前布局」重复"))
        if case .invalid? = status[.restore] {} else { XCTFail() }
    }
    func testDisabledAndCleared() {
        var settings=HotkeySettings.defaults; settings.enabled=false
        XCTAssertEqual(Set(HotkeyRegistrar.register(settings) { _,_ in XCTFail(); return true }.values),[.off])
        settings.enabled=true; settings.keys[.undo]=nil
        XCTAssertEqual(HotkeyRegistrar.register(settings) { _,_ in true }[.undo],.unset)
    }
    func testDisplayAndRoundTrip() throws {
        let key=Hotkey(keyCode:1,modifiers:[.command,.shift,.control,.option])
        XCTAssertEqual(key.display,"⌃⌥⇧⌘S")
        let data=try JSONEncoder().encode(HotkeySettings.defaults)
        XCTAssertEqual(try JSONDecoder().decode(HotkeySettings.self,from:data),.defaults)
    }
}

final class ReconnectPolicyTests: XCTestCase {
    func testSeenNameLabelsDisconnectedScreensAndDoesNotKeepEmptyEntries() {
        var prefs=MonitorPreferences()
        prefs.setRestore(.auto,for:"k",seenName:"DELL U2720Q")
        XCTAssertEqual(prefs.entries["k"]?.label,"DELL U2720Q")
        prefs.setDisplayName("家里",for:"k")
        XCTAssertEqual(prefs.entries["k"]?.label,"家里")
        XCTAssertEqual(prefs.entries["k"]?.seenName,"DELL U2720Q")
        prefs.setDisplayName(nil,for:"k"); prefs.setRestore(nil,for:"k")
        XCTAssertNil(prefs.entries["k"],"only a name the user typed or a choice keeps an entry")
        let old=try! JSONDecoder().decode(MonitorPreferences.self,from:Data(#"{"entries":{"x":{"restore":"off"}}}"#.utf8))
        XCTAssertEqual(old.restore("x"),.off)
        XCTAssertEqual(old.entries["x"]?.label,"外接屏")
    }

    let now=Date(timeIntervalSince1970:1_800_000_000)
    func testAskOnceThenRememberedChoiceOverridesGlobal() {
        XCTAssertEqual(ReconnectPolicy.action(global:.ask,perMonitor:nil,pausedUntil:nil,now:now),.askOnce)
        var prefs=MonitorPreferences()
        prefs.setRestore(AskOnceAnswer.automatic.mode,for:"m1")
        XCTAssertEqual(ReconnectPolicy.action(global:.ask,perMonitor:prefs.restore("m1"),pausedUntil:nil,now:now),.auto)
        XCTAssertEqual(ReconnectPolicy.action(global:.off,perMonitor:prefs.restore("m1"),pausedUntil:nil,now:now),.auto)
        prefs.setRestore(AskOnceAnswer.askEachTime.mode,for:"m1")
        XCTAssertEqual(ReconnectPolicy.action(global:.ask,perMonitor:prefs.restore("m1"),pausedUntil:nil,now:now),.ask)
        prefs.setRestore(AskOnceAnswer.never.mode,for:"m1")
        XCTAssertEqual(ReconnectPolicy.action(global:.auto,perMonitor:prefs.restore("m1"),pausedUntil:nil,now:now),.none)
        // Another monitor is still asked once.
        XCTAssertEqual(ReconnectPolicy.action(global:.ask,perMonitor:prefs.restore("m2"),pausedUntil:nil,now:now),.askOnce)
    }
    func testExplicitGlobalModesDoNotAsk() {
        XCTAssertEqual(ReconnectPolicy.action(global:.auto,perMonitor:nil,pausedUntil:nil,now:now),.auto)
        XCTAssertEqual(ReconnectPolicy.action(global:.off,perMonitor:nil,pausedUntil:nil,now:now),.none)
    }
    func testPauseWinsUntilItExpires() {
        let until=now.addingTimeInterval(60)
        XCTAssertEqual(ReconnectPolicy.action(global:.auto,perMonitor:.auto,pausedUntil:until,now:now),.paused)
        XCTAssertEqual(ReconnectPolicy.action(global:.auto,perMonitor:.auto,pausedUntil:until,now:until.addingTimeInterval(1)),.auto)
        var cal=Calendar(identifier:.gregorian); cal.timeZone=TimeZone.current
        let evening=cal.date(from:DateComponents(year:2026,month:10,day:11,hour:23,minute:10))!
        XCTAssertEqual(AutoRestorePause.untilTomorrow.until(from:evening,calendar:cal),cal.date(from:DateComponents(year:2026,month:10,day:12))!)
        XCTAssertEqual(AutoRestorePause.oneHour.until(from:evening),evening.addingTimeInterval(3600))
    }
    func testDisplayNamesArePerMonitorAndClearable() throws {
        let m=MonitorIdentity(vendor:1,model:2,serial:3,name:"DELL SE2416H")
        var prefs=MonitorPreferences()
        XCTAssertEqual(prefs.displayName(m),"DELL SE2416H")
        prefs.setDisplayName("  公司 ",for:m.key)
        XCTAssertEqual(prefs.displayName(m),"公司")
        let decoded=try JSONDecoder().decode(MonitorPreferences.self,from:JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.displayName(m),"公司")
        prefs.setDisplayName("",for:m.key)
        XCTAssertTrue(prefs.entries.isEmpty)
    }
}

final class FrameSettleTests: XCTestCase {
    let t0=Date(timeIntervalSince1970:1000)
    func testSettlesAfterOneQuietSecond() {
        var settle=FrameSettle()
        let a=["1:1":Rect(0,0,100,100)]
        XCTAssertEqual(settle.observe(a,at:t0),.waiting)
        XCTAssertEqual(settle.observe(["1:1":Rect(50,0,100,100)],at:t0+0.5),.waiting)
        XCTAssertEqual(settle.observe(["1:1":Rect(50.4,0,100,100)],at:t0+1.0),.waiting) // sub-point jitter is not movement
        XCTAssertEqual(settle.observe(["1:1":Rect(50,0,100,100)],at:t0+1.5),.settled)
    }
    func testNewOrVanishedWindowsCountAsChange() {
        var settle=FrameSettle()
        _=settle.observe(["1:1":Rect(0,0,10,10)],at:t0)
        XCTAssertEqual(settle.observe(["1:1":Rect(0,0,10,10),"1:2":Rect(0,0,10,10)],at:t0+0.9),.waiting)
        XCTAssertEqual(settle.observe(["1:1":Rect(0,0,10,10),"1:2":Rect(0,0,10,10)],at:t0+1.5),.waiting)
        XCTAssertEqual(settle.observe(["1:1":Rect(0,0,10,10),"1:2":Rect(0,0,10,10)],at:t0+1.9),.settled)
    }
    func testGivesUpAfterMaxWait() {
        var settle=FrameSettle()
        var x=0.0
        var decision=FrameSettle.Decision.waiting
        var t=t0
        while decision == .waiting { decision=settle.observe(["1:1":Rect(x,0,10,10)],at:t); x+=5; t+=0.25 }
        XCTAssertEqual(decision,.timedOut)
        XCTAssertEqual(t.timeIntervalSince(t0),5.25,accuracy:0.001)
    }
}

final class MainWindowStateTests: XCTestCase {
    func plan(_ states: [QuickItemState]) -> QuickRestorePlan {
        QuickRestorePlan(items:states.enumerated().map{ i,s in QuickRestoreItem(savedIndex:i,bundleID:"a",savedTitle:"t",currentTitle:nil,currentSlot:1,targetSlot:1,chosenToken:nil,candidates:[],matchKind:.title,state:s,reason:"") },
                         plan:RestorePlan(session:UUID(),topology:"t",entries:[]),entrySavedIndex:[],desktopsNow:1,desktopsNeeded:1)
    }
    func testStatesAndPrimaryButton() {
        XCTAssertEqual(MainWindowState.derive(hasMonitor:false,trusted:true,hasLayout:true,plan:nil),.noMonitor)
        XCTAssertEqual(MainWindowState.derive(hasMonitor:true,trusted:false,hasLayout:true,plan:nil),.needsPermission)
        let notSaved=MainWindowState.derive(hasMonitor:true,trusted:true,hasLayout:false,plan:nil)
        XCTAssertEqual(notSaved,.notSaved); XCTAssertEqual(notSaved.primary,.save)
        XCTAssertEqual(MainWindowState.derive(hasMonitor:true,trusted:true,hasLayout:true,plan:nil).primary,.restore)
        let differs=MainWindowState.derive(hasMonitor:true,trusted:true,hasLayout:true,plan:plan([.alreadyInPlace,.ready,.needsConfirmation]))
        XCTAssertEqual(differs,.differs(ready:1,needsConfirmation:1)); XCTAssertEqual(differs.primary,.restore)
        let matches=MainWindowState.derive(hasMonitor:true,trusted:true,hasLayout:true,plan:plan([.alreadyInPlace,.alreadyInPlace,.missing,.blocked]))
        XCTAssertEqual(matches,.matches(notRestorable:2)); XCTAssertEqual(matches.primary,.none)
        XCTAssertEqual(MainWindowState.derive(hasMonitor:true,trusted:true,hasLayout:true,plan:plan([.needsConfirmation])),.differs(ready:0,needsConfirmation:1))
    }

    func testSwitchLayoutsSubmenuListsNamedLayoutsOfConnectedScreen() {
        var s=MenuState(); s.monitorName="公司"; s.windowCount=3; s.savedAt=Date()
        XCTAssertNil(StatusMenuModel.build(s).first{$0.id=="layouts"})
        s.layouts=[MenuLayout(name:"写代码",active:true),MenuLayout(name:"开会",active:false)]
        let sub=StatusMenuModel.build(s).first{$0.id=="layouts"}
        XCTAssertEqual(sub?.title,"切换版式")
        XCTAssertEqual(sub?.children.filter{$0.kind == .action}.map(\.title),["写代码","开会","管理版式…"])
        XCTAssertEqual(sub?.children.first?.checked,true)
        s.trusted=false
        XCTAssertEqual(StatusMenuModel.build(s).first{$0.id=="layouts"}?.children.first?.enabled,false)
        s.monitorName=nil
        XCTAssertNil(StatusMenuModel.build(s).first{$0.id=="layouts"})
    }
}
