// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class NoticeRoutingTests: XCTestCase {
    func testActionIdentifiersRoundTrip() {
        for a in NoticeAction.allCases { XCTAssertEqual(NoticeAction(identifier:a.identifier),a) }
        XCTAssertNil(NoticeAction(identifier:"com.apple.UNNotificationDefaultActionIdentifier"))
        XCTAssertNil(NoticeAction(identifier:"com.apple.UNNotificationDismissActionIdentifier"))
        XCTAssertNil(NoticeAction(identifier:"lk.action.unknown"))
        XCTAssertEqual(Set(NoticeAction.allCases.map(\.identifier)).count,NoticeAction.allCases.count)
    }
    func testTitlesKeepTheOldButtonWording() {
        XCTAssertEqual(NoticeAction.view.title,"查看"); XCTAssertEqual(NoticeAction.retry.title,"重试")
        XCTAssertEqual(NoticeAction.restoreNow.title,"恢复布局"); XCTAssertEqual(NoticeAction.undo.title,"撤销")
        XCTAssertEqual(NoticeAction.openMissionControl.title,"打开调度中心"); XCTAssertEqual(NoticeAction.openSettings.title,"打开设置")
        XCTAssertEqual(NoticeAction.saveNow.title,"现在保存")
        // Only 「查看」 needs our window in front; Undo / Retry run without stealing focus.
        XCTAssertEqual(NoticeAction.allCases.filter(\.opensApp),[.view])
    }
    func testCategoryPerButtonSet() {
        XCTAssertEqual(NoticeRouting.categoryID([]),"lk.notice")
        XCTAssertEqual(NoticeRouting.categoryID([.retry,.undo,.view]),"lk.notice.retry+undo+view")
        XCTAssertNotEqual(NoticeRouting.categoryID([.retry,.view]),NoticeRouting.categoryID([.view,.retry]))   // order = button order
        let ids=NoticeRouting.knownActionSets.map(NoticeRouting.categoryID)
        XCTAssertEqual(Set(ids).count,ids.count,"each known set registered once")
        // Every button set the app posts today is pre-registered at launch (restore results, shared notices, reconnect, library undo, first-layout reminder).
        for set: [NoticeAction] in [[.retry,.view],[.view],[.restoreNow,.view],[.undo,.view],[.retry,.undo,.view],[.restoreNow],[.undo],[.openMissionControl],[.openSettings],[.saveNow],[]] {
            XCTAssertTrue(ids.contains(NoticeRouting.categoryID(set)),"\(set)")
        }
    }
    func testRetention() {
        XCTAssertNil(NoticeRouting.retention(duration:0))                  // needs attention: stays until dismissed
        XCTAssertEqual(NoticeRouting.retention(duration:2),NoticeRouting.minimumRetention)   // never cut the system banner short
        XCTAssertEqual(NoticeRouting.retention(duration:15),15)
    }
    func testDeliveryNeverLosesANotice() {
        XCTAssertEqual(NoticeRouting.delivery(.allowed,alreadyRequested:false),.post)
        XCTAssertEqual(NoticeRouting.delivery(.alertsOff,alreadyRequested:true),.postAndKeepInMenu)
        XCTAssertEqual(NoticeRouting.delivery(.notDetermined,alreadyRequested:false),.requestThenPost)
        XCTAssertEqual(NoticeRouting.delivery(.notDetermined,alreadyRequested:true),.menuOnly)   // asked once this launch: no loop, no repeat prompts
        XCTAssertEqual(NoticeRouting.delivery(.denied,alreadyRequested:false),.menuOnly)
        XCTAssertEqual(NoticeRouting.delivery(.unavailable,alreadyRequested:false),.menuOnly)
    }
    func testMenuSubtitle() {
        XCTAssertNil(NoticeRouting.menuSubtitle(nil)); XCTAssertNil(NoticeRouting.menuSubtitle("  "))
        XCTAssertEqual(NoticeRouting.menuSubtitle("短"),"短")
        let long=String(repeating:"字",count:200)
        let cut=NoticeRouting.menuSubtitle(long,limit:80)!
        XCTAssertEqual(cut.count,80); XCTAssertTrue(cut.hasSuffix("…"))
    }
    func testUndeliveredNoticeIsListedInTheMenu() {
        var s=MenuState(); s.monitorName="DELL"; s.savedAt=Date(); s.windowCount=3
        XCTAssertFalse(StatusMenuModel.build(s).contains{ $0.id == "notice" })
        s.pendingNotice="没有自动恢复"; s.pendingNoticeDetail="这块屏幕尚未保存布局"
        let items=StatusMenuModel.build(s)
        XCTAssertEqual(items[0].id,"status"); XCTAssertEqual(items[1].id,"notice")
        XCTAssertEqual(items[1].title,"没有自动恢复"); XCTAssertEqual(items[1].reason,"这块屏幕尚未保存布局"); XCTAssertTrue(items[1].enabled)
    }
}

/// 0.6.8: the unplug notice "N 个桌面被移到了内置屏" is gone, and nothing may tell the user that deleting the desktops
/// macOS moved to the built-in screen is safe (deleting one renumbers the desktops the saved layout refers to).
final class MigratedDesktopNoticeTests: XCTestCase {
    func testNoSourceOrStringSaysDeletingMigratedDesktopsIsSafe() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files=[root.appendingPathComponent("Resources/en.lproj/Localizable.strings")]
        for dir in ["Sources","Resources"] {
            let e=FileManager.default.enumerator(at:root.appendingPathComponent(dir),includingPropertiesForKeys:nil)
            while let u=e?.nextObject() as? URL { if ["swift","strings"].contains(u.pathExtension) { files.append(u) } }
        }
        for name in ["README.md","README.zh-CN.md","README.ja.md","README.ko.md","README.vi.md"] { files.append(root.appendingPathComponent(name)) }
        XCTAssertGreaterThan(files.count,20)
        for f in files {
            let text=try String(contentsOf:f,encoding:.utf8)
            // 0.6.9: windows are never piled onto the last desktop any more, so nothing may promise or describe that.
            for banned in ["删了也不会丢","被移到了内置屏","已自动删掉 %@ 个空桌面","so nothing is lost","最后一个桌面","the last desktop","can adjust the monitor's speakers"] {
                XCTAssertFalse(text.contains(banned),"\(f.lastPathComponent) still contains \(banned)")
            }
        }
    }
}
