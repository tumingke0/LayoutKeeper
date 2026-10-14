// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

/// `--render-ui-snapshots <dir>`: renders the redesigned views with sample data to PNG files.
/// No Accessibility calls, no window reads or writes; windows are created offscreen and never shown.
/// Never ordered on screen; reports key/main so AppKit draws controls in their active appearance.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

enum UISnapshots {
    static let monitor=MonitorIdentity(vendor:4268,model:53378,serial:1,name:"DELL SE2416H")
    static func saved(_ bundle: String,_ title: String,slot: Int,_ f: Rect) -> SavedWindow {
        SavedWindow(selector:WindowSelector(bundleID:bundle,title:title),displayRole:.external,desktopLabel:"组\(slot)",normalizedFrame:f,desktopIndex:slot)
    }
    static func sampleRecord() -> MonitorLayoutRecord {
        let windows=[
            saved("com.google.Chrome","项目计划",slot:3,Rect(0.02,0.03,0.96,0.94)),
            saved("com.google.Chrome","阅读清单",slot:2,Rect(0.02,0.04,0.55,0.92)),
            saved("com.apple.Safari","开发者文档",slot:4,Rect(0.05,0.05,0.6,0.9)),
            saved("com.apple.Terminal","示例项目 — zsh",slot:1,Rect(0.0,0.0,1,1)),
            saved("com.apple.systempreferences","系统设置",slot:1,Rect(0.62,0.18,0.36,0.62)),
            saved("com.apple.finder","下载",slot:2,Rect(0.6,0.2,0.38,0.5)),
            saved("com.apple.Notes","备忘录",slot:4,Rect(0.55,0.1,0.43,0.8)),
        ]
        var r=MonitorLayoutRecord(monitor:monitor,profile:Profile(location:monitor.name,windows:windows))
        r.savedAt=Calendar.current.date(bySettingHour:9,minute:42,second:0,of:Date()) ?? Date()
        return r
    }
    static func sampleModel(record: MonitorLayoutRecord?, trusted: Bool = true, undo: Bool = true) -> Model {
        let m=Model()
        m.accessState=ControlAccessState(trusted:trusted,checkedAt:Date())
        m.externalMonitors=[ConnectedMonitor(identity:monitor,runtimeDisplayToken:"ext")]
        m.externalRecord=record
        if undo { m.lastRestoreJournal=sampleJournal() }
        sampleLibrary(m,record:record)
        return m
    }
    static let homeMonitor=MonitorIdentity(vendor:7789,model:23296,serial:2,name:"LG HDR 4K")
    static func day(_ offset: Int,_ h: Int,_ min: Int) -> Date {
        let d=Calendar.current.date(byAdding:.day,value:offset,to:Date()) ?? Date()
        return Calendar.current.date(bySettingHour:h,minute:min,second:0,of:d) ?? d
    }
    /// Two saved screens (this one connected, a home screen not connected) and a few versions; no files are read.
    static func sampleLibrary(_ m: Model,record: MonitorLayoutRecord?) {
        m.monitorPreferences.setDisplayName("公司",for:monitor.key,seenName:monitor.name)
        m.monitorPreferences.setDisplayName("家里",for:homeMonitor.key,seenName:homeMonitor.name)
        let connected=m.currentExternalMonitor != nil
        let current=SavedScreen(key:monitor.key,monitor:monitor,name:"公司",savedAt:record?.savedAt ?? .distantPast,windowCount:record?.profile.windows.count ?? 0,desktopCount:4,connected:connected)
        let home=SavedScreen(key:homeMonitor.key,monitor:homeMonitor,name:"家里",savedAt:day(-1,21,15),windowCount:5,desktopCount:3,connected:false)
        m.savedScreens=(record != nil || connected ? [current] : [])+[home]
        m.selectedScreenKey=m.savedScreens.first?.key
        m.selectedRecord=record
        guard let record else { m.screenVersions=[]; return }
        func v(_ n: Int,_ date: Date,_ w: Int,_ d: Int,current: Bool = false) -> LayoutVersion {
            LayoutVersion(url:URL(fileURLWithPath:"/tmp/lk-sample/\(n).json"),savedAt:date,windowCount:w,desktopCount:d,isCurrent:current)
        }
        var labelled=v(3,day(-3,10,12),4,3); labelled.label="季度汇报前"
        var cur=v(0,record.savedAt,record.profile.windows.count,4,current:true); cur.originName="写代码"
        var meeting=v(1,day(-1,18,3),3,2); meeting.originName="开会"
        var coding=v(4,day(-6,14,48),7,4); coding.originName="写代码"
        m.screenVersions=[cur,meeting,v(2,day(-1,9,30),6,3),labelled,coding]
        func n(_ i: Int,_ name: String,_ w: Int,_ d: Int,active: Bool = false) -> NamedLayout {
            NamedLayout(url:URL(fileURLWithPath:"/tmp/lk-sample/n\(i).json"),name:name,savedAt:day(-2,9,0),windowCount:w,desktopCount:d,isActive:active)
        }
        m.namedLayouts=[n(1,"写代码",record.profile.windows.count,4,active:true),n(2,"开会",3,2),n(3,"专注阅读",2,1)]
    }
    /// The home screen selected: saved but not connected.
    static func selectHome(_ m: Model) {
        m.selectedScreenKey=homeMonitor.key
        let windows=[saved("com.apple.Safari","阅读",slot:1,Rect(0.05,0.05,0.6,0.9)),saved("com.apple.Music","音乐",slot:1,Rect(0.6,0.1,0.38,0.6)),
                     saved("com.apple.Terminal","zsh",slot:2,Rect(0,0,1,1)),saved("com.apple.Notes","备忘录",slot:3,Rect(0.1,0.1,0.5,0.8)),saved("com.apple.finder","下载",slot:3,Rect(0.6,0.3,0.38,0.5))]
        var r=MonitorLayoutRecord(monitor:homeMonitor,profile:Profile(location:homeMonitor.name,windows:windows)); r.savedAt=day(-1,21,15)
        m.selectedRecord=r
        m.screenVersions=[LayoutVersion(url:URL(fileURLWithPath:"/tmp/lk-sample/h0.json"),savedAt:r.savedAt,windowCount:5,desktopCount:3,isCurrent:true),
                          LayoutVersion(url:URL(fileURLWithPath:"/tmp/lk-sample/h1.json"),savedAt:day(-8,20,40),windowCount:4,desktopCount:3,isCurrent:false)]
        m.namedLayouts=[NamedLayout(url:URL(fileURLWithPath:"/tmp/lk-sample/hn1.json"),name:"周末娱乐",savedAt:day(-8,20,0),windowCount:5,desktopCount:3,isActive:true)]
    }
    static func sampleJournal() -> RestoreJournal? {
        let w=ObservedWindow(token:"1:1",selector:WindowSelector(bundleID:"com.google.Chrome",title:"x"),frame:Rect(0,0,800,600),spaceIDs:[1],processStartedAt:Date(timeIntervalSince1970:1000))
        guard let wd=try? JSONEncoder().encode(w),let wo=try? JSONSerialization.jsonObject(with:wd) else { return nil }
        let j: [String:Any]=["schemaVersion":1,"id":UUID().uuidString,"createdAt":0,"session":UUID().uuidString,"topology":"t",
                             "entries":[["planIndex":0,"before":wo,"targetFrame":["x":0,"y":0,"width":10,"height":10],"targetDisplay":"ext","state":"verified","detail":"","after":wo]]]
        guard let data=try? JSONSerialization.data(withJSONObject:j) else { return nil }
        return try? JSONDecoder().decode(RestoreJournal.self,from:data)
    }
    static func samplePlan(_ m: Model,record: MonitorLayoutRecord) {
        let visible=Rect(0,0,1920,1050)
        func live(_ token: String,_ bundle: String,_ title: String,space: UInt64,_ f: Rect,started: Bool = true) -> ObservedWindow {
            ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title),frame:f,spaceIDs:[space],processStartedAt:started ? Date(timeIntervalSince1970:1000) : nil)
        }
        let s=Snapshot(session:UUID(),topology:"t",
            displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,1050,1512,945)),Display(token:"ext",name:monitor.name,role:.external,visible:visible)],
            spaces:[Space(id:10,displayToken:"builtin",active:true),Space(id:101,displayToken:"ext",active:true),Space(id:102,displayToken:"ext"),Space(id:103,displayToken:"ext"),Space(id:104,displayToken:"ext")],
            windows:[
                live("1:1","com.google.Chrome","项目计划",space:101,Rect(200,100,1000,700)),
                live("1:2","com.google.Chrome","阅读清单",space:102,Rect(0.02,0.04,0.55,0.92).fitted(in:visible)),
                live("5:1","com.apple.Safari","开发者文档",space:10,Rect(40,1100,900,700)),
                live("2:1","com.apple.Terminal","示例项目 — zsh",space:102,Rect(100,100,1400,900)),
                live("3:1","com.apple.systempreferences","系统设置",space:101,Rect(300,200,700,650)),
                live("691:1","com.apple.finder","下载",space:103,Rect(500,300,700,500),started:false),
                live("4:1","com.apple.Notes","备忘录",space:103,Rect(900,100,800,800)),
                live("4:2","com.apple.Notes","备忘录",space:101,Rect(100,500,600,400)),
            ])
        m.quickRecord=record; m.quickSnapshot=s; m.quickDisplayToken="ext"; m.quickMonitor=monitor
        m.quickPlan=try? QuickRestorePlanner.plan(record:record,monitor:monitor,displayToken:"ext",snapshot:s,allowCrossSpace:true)
    }
    @discardableResult static func render<V: View>(_ view: V,to url: URL,dark: Bool = false) -> Bool {
        let hosting=NSHostingView(rootView:view.background(Color(nsColor:.windowBackgroundColor)))
        let size=hosting.fittingSize
        let window=SnapshotWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
        window.contentView=hosting; hosting.frame=NSRect(origin:.zero,size:size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let rep=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else { return false }
        hosting.cacheDisplay(in:hosting.bounds,to:rep)
        guard let png=rep.representation(using:.png,properties:[:]) else { return false }
        do { try png.write(to:url); print("wrote \(url.path) \(Int(size.width))x\(Int(size.height))"); return true } catch { return false }
    }
    /// A live snapshot where every saved window already sits where it was saved (→ "matches").
    static func matchingSnapshot(_ record: MonitorLayoutRecord) -> Snapshot {
        let visible=Rect(0,0,1920,1050)
        let windows=record.profile.windows.enumerated().map { i,w in
            ObservedWindow(token:"\(i+1):1",selector:w.selector,frame:w.normalizedFrame.fitted(in:visible),spaceIDs:[UInt64(100+(w.desktopIndex ?? 1))],processStartedAt:Date(timeIntervalSince1970:1000))
        }
        return Snapshot(session:UUID(),topology:"t",
            displays:[Display(token:"builtin",name:"内建",role:.builtIn,visible:Rect(0,1050,1512,945)),Display(token:"ext",name:monitor.name,role:.external,visible:visible)],
            spaces:[Space(id:10,displayToken:"builtin",active:true),Space(id:101,displayToken:"ext",active:true),Space(id:102,displayToken:"ext"),Space(id:103,displayToken:"ext"),Space(id:104,displayToken:"ext")],
            windows:windows)
    }
    static func setLive(_ m: Model,_ plan: QuickRestorePlan?) { m.livePlan=plan; m.livePlanKey=m.liveKey }
    static func run(to dir: URL) -> Int32 {
        RenderMode.snapshot=true
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let record=sampleRecord()
        var ok=true
        func shot<V: View>(_ name: String,_ view: V,dark: Bool = false) { ok=render(view,to:dir.appendingPathComponent(name),dark:dark) && ok }

        // Main window: three states.
        let notSaved=sampleModel(record:nil,undo:false)
        shot("01-main-not-saved.png",MainView(model:notSaved))
        let differs=sampleModel(record:record,undo:false)
        samplePlan(differs,record:record); setLive(differs,differs.quickPlan)
        shot("02-main-differs.png",MainView(model:differs))
        let matches=sampleModel(record:record)
        setLive(matches,try? QuickRestorePlanner.plan(record:record,monitor:monitor,displayToken:"ext",snapshot:matchingSnapshot(record),allowCrossSpace:true))
        matches.lastRestoreSummary=RestoreSummary(at:Calendar.current.date(bySettingHour:9,minute:50,second:0,of:Date()) ?? Date(),restored:6,needsConfirmation:1,failed:0)
        shot("03-main-matches.png",MainView(model:matches))
        shot("04-main-matches-dark.png",MainView(model:matches),dark:true)
        shot("05-main-needs-permission.png",MainView(model:sampleModel(record:record,trusted:false,undo:false)))
        let away=sampleModel(record:record,undo:false); selectHome(away)
        shot("05b-main-disconnected-screen.png",MainView(model:away))
        let previewing=sampleModel(record:record,undo:false)
        setLive(previewing,try? QuickRestorePlanner.plan(record:record,monitor:monitor,displayToken:"ext",snapshot:matchingSnapshot(record),allowCrossSpace:true))
        var older=record; older.profile.windows=Array(record.profile.windows.prefix(6)); older.savedAt=day(-1,18,3)
        previewing.previewVersion=previewing.screenVersions[1]; previewing.previewRecord=older
        shot("05c-main-preview-version.png",MainView(model:previewing))
        let empty=sampleModel(record:nil,undo:false); empty.externalMonitors=[]; empty.savedScreens=[]; empty.selectedScreenKey=nil
        shot("05d-main-empty.png",MainView(model:empty))

        // Menu bar menu, from the same item model as the real NSMenu.
        let menuModel=sampleModel(record:record)
        shot("06-menu.png",MenuReplica(items:StatusMenuModel.build(menuModel.menuState(optionHeld:false)),expand:"mode"))
        shot("06b-menu-switch-layouts.png",MenuReplica(items:StatusMenuModel.build(menuModel.menuState(optionHeld:false)),expand:"layouts"))
        shot("07-menu-option.png",MenuReplica(items:StatusMenuModel.build(menuModel.menuState(optionHeld:true))))
        let noScreen=sampleModel(record:nil,undo:false); noScreen.externalMonitors=[]
        shot("08-menu-no-screen.png",MenuReplica(items:StatusMenuModel.build(noScreen.menuState(optionHeld:false))))

        // Toast after an automatic restore, and the reconnect prompts.
        if let toast=menuModel.restoreToast(DirectRestoreOutcome(restored:6,attempted:6,needsConfirmation:1),trigger:.automatic) {
            shot("09-toast-auto-restore.png",ToastView(toast:toast,actions:toast.actions).padding(16))
            shot("10-toast-auto-restore-dark.png",ToastView(toast:toast,actions:toast.actions).padding(16),dark:true)
        }
        shot("11-ask-once.png",ReconnectPanelView(prompt:ReconnectCoordinator.askOncePrompt(name:monitor.name,automatic:{},askEachTime:{},never:{})))
        shot("12-ask-each-time.png",ReconnectPanelView(prompt:ReconnectCoordinator.askPrompt(name:"公司",restore:{},preview:{})))

        // Standalone preview / results panel.
        let sheet=sampleModel(record:record)
        samplePlan(sheet,record:record)
        shot("13-preview-panel.png",QuickRestoreSheet(model:sheet,onClose:{}))
        shot("14-preview-panel-details.png",QuickRestoreSheet(model:sheet,onClose:{},showDetails:true))
        if let plan=sheet.quickPlan {
            for item in plan.items where item.state == .ready { sheet.quickResults[item.savedIndex]=RestoreResult(title:item.savedTitle,outcome:.verified,detail:"已回读确认") }
            if var after=sheet.quickSnapshot {
                for item in plan.items where item.state == .ready {
                    guard let token=item.chosenToken,let i=after.windows.firstIndex(where:{$0.token==token}) else { continue }
                    if let frame=item.targetFrame { after.windows[i].frame=frame }
                    if let slot=item.targetSlot { after.windows[i].spaceIDs=[UInt64(100+slot)] }
                }
                sheet.quickSnapshot=after
                sheet.quickPlan=try? QuickRestorePlanner.plan(record:record,monitor:monitor,displayToken:"ext",snapshot:after,allowCrossSpace:true)
            }
            sheet.quickMessage="已恢复 \(plan.readyCount)/\(plan.readyCount) 个窗口（桌面、位置和大小均已回读确认）。"
        }
        shot("15-preview-results.png",QuickRestoreSheet(model:sheet,onClose:{}))

        // Settings (general shows hotkeys, remembered screens, pause; one hotkey shows a conflict example).
        let settings=sampleModel(record:record)
        settings.monitorPreferences.setDisplayName("公司",for:monitor.key,seenName:monitor.name)
        settings.monitorPreferences.setRestore(.auto,for:monitor.key)
        settings.hotkeyStatus=[.save:.active,.restore:.active,.undo:.conflict("⌃⌥⌘Z 注册失败：可能已被系统或其他应用占用，请换一个")]
        for (i,tab) in SettingsTab.allCases.enumerated() {
            settings.settingsTab=tab
            shot("\(16+i)-settings-\(tab.rawValue).png",SettingsView(model:settings))
        }
        // 0.6.2: 布局模式 and the closable notices.
        let shared=sampleModel(record:record)
        shared.layoutMode = .sharedExternal; MonitorRecognition.layoutMode = .perMonitor
        shared.settingsTab = .general
        shot("25-settings-layout-mode-shared.png",SettingsView(model:shared))
        shared.snapshotSeparateSpacesOff=true
        shot("26-settings-layout-mode-hint.png",SettingsView(model:shared))
        let perMonitor=sampleModel(record:record); perMonitor.settingsTab = .general
        shot("27-settings-layout-mode-per-monitor.png",SettingsView(model:perMonitor))
        for (name,notice) in [("28-toast-missing-spaces.png",SharedNotice(kind:.missingSpaces(2))),("29-toast-spaces-moved.png",SharedNotice(kind:.migrated(5))),
                              ("30-toast-separate-spaces-off.png",SharedNotice(kind:.separateSpacesOff))] {
            let toast=shared.sharedNoticeToast(notice)
            shot(name,ToastView(toast:toast,actions:toast.actions).padding(16))
        }
        let reconnectToast=ReconnectCoordinator.reconnectNotice(name:"公司",restore:{})
        shot("31-toast-reconnect.png",ToastView(toast:reconnectToast,actions:reconnectToast.actions).padding(16))
        shot("32-toast-reconnect-dark.png",ToastView(toast:reconnectToast,actions:reconnectToast.actions).padding(16),dark:true)
        // First-run guide (sample models; nothing is requested from the system).
        let fresh=sampleModel(record:nil,trusted:false,undo:false)
        let step1=OnboardingController(model:fresh,reason:.firstRun)
        shot("19-onboarding-1-permission.png",OnboardingView(controller:step1))
        let granted=OnboardingController(model:sampleModel(record:nil,undo:false),reason:.firstRun)
        var g=OnboardingFlow(reason:.firstRun,trusted:false); g.observePermission(true); granted.flow=g; granted.justGranted=true
        shot("20-onboarding-1-granted.png",OnboardingView(controller:granted))
        let step2=OnboardingController(model:sampleModel(record:nil,undo:false),reason:.firstRun)
        var f2=OnboardingFlow(reason:.firstRun,trusted:true); f2.advance(); step2.flow=f2
        shot("21-onboarding-2-launch-at-login.png",OnboardingView(controller:step2))
        let step3=OnboardingController(model:sampleModel(record:nil,undo:false),reason:.firstRun)
        var f3=f2; f3.advance(); step3.flow=f3
        shot("22-onboarding-3-save.png",OnboardingView(controller:step3))
        let noScreen3=sampleModel(record:nil,undo:false); noScreen3.externalMonitors=[]
        let step3b=OnboardingController(model:noScreen3,reason:.firstRun); step3b.flow=f3
        shot("23-onboarding-3-no-monitor.png",OnboardingView(controller:step3b))
        shot("24-onboarding-1-permission-dark.png",OnboardingView(controller:step1),dark:true)
        return ok ? 0 : 1
    }
}

/// Draws the status menu exactly as described by `StatusMenuModel` (used only for screenshots).
struct MenuReplica: View {
    let items: [MenuItemModel]
    var expand: String?=nil
    var body: some View {
        HStack(alignment:.top,spacing:2) {
            column(items,width:300)
            if let id=expand,let item=items.first(where:{$0.id==id}) {
                column(item.children,width:250).padding(.top,offset(of:id))
            }
        }.padding(14)
    }
    private func offset(of id: String) -> CGFloat {
        var y: CGFloat=5
        for item in items { if item.id==id { break }; y+=height(item) }
        return y-5
    }
    private func height(_ item: MenuItemModel) -> CGFloat { item.kind == .separator ? 11 : (item.reason != nil && !item.enabled ? 38 : 24) }
    private func column(_ list: [MenuItemModel],width: CGFloat) -> some View {
        VStack(alignment:.leading,spacing:0) {
            ForEach(list) { item in row(item).frame(height:height(item)) }
        }
        .padding(5).frame(width:width)
        .background(RoundedRectangle(cornerRadius:10,style:.continuous).fill(Color(nsColor:.windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius:10,style:.continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color:.black.opacity(0.18),radius:10,y:4)
    }
    @ViewBuilder private func row(_ item: MenuItemModel) -> some View {
        switch item.kind {
        case .separator: Divider().padding(.horizontal,8)
        case .status: Text(item.title).font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,10).frame(maxWidth:.infinity,alignment:.leading)
        default:
            let highlighted=item.id==expand
            HStack(spacing:6) {
                Image(systemName:"checkmark").font(.system(size:11,weight:.semibold)).opacity(item.checked ? 1 : 0).frame(width:12)
                if let symbol=item.symbol { Image(systemName:symbol).font(.system(size:12)).frame(width:16) }
                VStack(alignment:.leading,spacing:1) {
                    Text(item.title).font(.system(size:13))
                    if !item.enabled,let reason=item.reason { Text(reason).font(.system(size:11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength:12)
                if item.kind == .submenu { Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)) }
                else if item.enabled,let shortcut=item.shortcutText { Text(shortcut).font(.system(size:13)).foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary) }
            }
            .foregroundStyle(highlighted ? Color.white : (item.enabled ? Color.primary : Color.secondary.opacity(0.7)))
            .padding(.horizontal,6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:5).fill(highlighted ? Color.accentColor : .clear))
        }
    }
}
