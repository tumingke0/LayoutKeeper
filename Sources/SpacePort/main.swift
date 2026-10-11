// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters
import SpaceProbe

final class Model: ObservableObject {
    let spaces=ReadOnlySpaces()
    lazy var windows=AXWindows(spaces:spaces)
    @Published var diagnostic=""
    @Published var location="家"
    @Published var desktopLabel="开发"
    @Published var role=DisplayRole.external
    @Published var snapshot: Snapshot?
    @Published var bindings: [DesktopBinding]=[]
    @Published var profiles: [String:Profile]=[:]
    @Published var preview: RestorePlan?
    @Published var message="先查看诊断；实际窗口测试需批准辅助功能权限。"
    @Published var results: [RestoreResult]=[]
    @Published var fixtureOnly=true
    @Published var restoring=false
    @Published var mode=GuidedMode.simulation
    @Published var demoSnapshot=GuidedDemoBackend().state
    @Published var guidedPreview: RestorePlan?
    @Published var guidedResults: [RestoreResult]=[]
    @Published var guidedMessage="先选家或公司，再点保存布局。安全演示不会操作你的软件窗口。"
    @Published var guidedProfiles: [String:Profile]=[:]
    @Published var accessState=ControlAccessState()
    @Published var settingsMessage=""
    let accessMonitor=ControlAccessMonitor()
    var trusted: Bool { accessState.canReadWindows }
    var versionLabel: String {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版本"
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "未打包"
        return "版本 \(version) (\(build)) · \(AppInstallation.role(bundleURL:Bundle.main.bundleURL))"
    }
    func refreshAuthorization() { accessState=accessMonitor.check() }
    func openControlSettings() {
        let opened=ControlSettings.open(using:{ NSWorkspace.shared.open($0) })
        let panel=ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "设备控制和数据访问" : "辅助功能"
        settingsMessage=opened ? "请在“隐私与安全性 → \(panel)”允许 LayoutKeeper。应用会自动检查结果。" : "系统设置未能打开。请手动在“隐私与安全性 → \(panel)”允许 LayoutKeeper。"
    }
    @Published var externalMonitors: [ConnectedMonitor]=[]
    @Published var externalRecord: MonitorLayoutRecord?
    @Published var externalMessage=""
    @Published var externalRestoreSnapshot: Snapshot?
    @Published var externalRestorePlan: RestorePlan?
    @Published var externalRestoreRecord: MonitorLayoutRecord?
    @Published var externalGroupSpaces: [String:UInt64]=[:]
    @Published var externalRestoreResults: [RestoreResult]=[]
    @Published var externalRestoreMessage=""
    @Published var lastRestoreJournal: RestoreJournal?
    var lastRestoreJournalURL: URL?
    @Published var externalCrossSpaceAllowed=false
    var lastRestorePermits: [SpaceMovePermit]=[]
    @Published var fixtureSpaceSnapshot: Snapshot?
    @Published var fixtureSpacePlan: RestorePlan?
    @Published var fixtureSpaceResults: [RestoreResult]=[]
    @Published var fixtureSpaceMessage=""
    @Published var fixtureSpaceJournal: RestoreJournal?
    var fixtureSpaceJournalURL: URL?
    var fixtureSpacePermits: [SpaceMovePermit]=[]
    var restoreDisplayToken: String?
    let guidedDemo=GuidedDemoBackend()
    var guidedBindings: [DesktopBinding]=[]
    var guidedBindingArchive: [String:[DesktopBinding]]=[:]
    var guidedStorageOverride: URL?
    var emptyWindowTrial: EmptyWindowTrial?
    @Published var trialConfigurationError=""
    @Published var captureInspection:CapturePipelineReport?
    @Published var captureInspectionMessage=""
    @Published var checkingCapture=false
    /// Runtime-only per-window trace of the last scan (contains window IDs; never written to layout files).
    @Published var captureTrace:[CaptureTraceEntry]=[]
    var captureInspectionMonitorKey:String?
    @Published var selfTestRunning=false
    @Published var selfTestProgress=""
    @Published var selfTestSummary=""
    @Published var selfTestReportText=""
    @Published var selfTestReportURL: URL?
    var selfTestRun: SelfTestRun?
    var fixtures: [NSWindow]=[]
    @Published var quickPlan: QuickRestorePlan?
    @Published var quickChoices: [Int:QuickChoice]=[:]
    @Published var quickResults: [Int:RestoreResult]=[:]
    @Published var quickMessage=""
    @Published var showingQuickRestore=false
    var quickRecord: MonitorLayoutRecord?
    var quickSnapshot: Snapshot?
    var quickDisplayToken: String?
    var quickMonitor: MonitorIdentity?
    var appNameCache: [String:String]=[:]
    var cachedCrossSpaceSupport: CrossSpaceSupport?
    @Published var actionNote: ActionNote?
    @Published var settingsTab=SettingsTab.general
    var openSettings: ((SettingsTab) -> Void)?
    @Published var autoRestoreMode=AutoRestoreMode(rawValue:Prefs.store?.string(forKey:"autoRestoreMode") ?? "") ?? .defaultMode {
        didSet { Prefs.store?.set(autoRestoreMode.rawValue,forKey:"autoRestoreMode") }
    }
    @Published var monitorPreferences=Prefs.monitorPreferences() { didSet { Prefs.save(monitorPreferences,key:Prefs.monitorPreferencesKey) } }
    @Published var pausedUntil: Date?=Prefs.store?.object(forKey:Prefs.pausedUntilKey) as? Date {
        didSet { if let pausedUntil { Prefs.store?.set(pausedUntil,forKey:Prefs.pausedUntilKey) } else { Prefs.store?.removeObject(forKey:Prefs.pausedUntilKey) } }
    }
    @Published var hotkeySettings=Prefs.hotkeys() { didSet { Prefs.save(hotkeySettings,key:Prefs.hotkeysKey); applyHotkeys?() } }
    @Published var hotkeyStatus: [HotkeyAction:HotkeyStatus]=[:]
    @Published var recordingHotkey: HotkeyAction?
    /// Read-only plan for the main window's "differs / matches" state; computed with its own AX reader.
    @Published var livePlan: QuickRestorePlan?
    var livePlanKey: String?
    @Published var lastRestoreSummary: RestoreSummary?
    var showToast: ((Toast) -> Void)?
    var openPreviewPanel: ((Bool) -> Void)?
    var applyHotkeys: (() -> Void)?
    var openOnboarding: (() -> Void)?
    var suspendHotkeys: ((Bool) -> Void)?
    var requestLiveCheck: (() -> Void)?
    /// Separate reader so background status checks never replace the handles a restore/undo relies on.
    lazy var statusWindows: AXWindows={ let w=AXWindows(spaces:spaces); w.remoteSearchTotal=1.5; w.remoteSearchPerApp=0.4; return w }()
    var currentProfile: Profile { profiles[location] ?? Profile(location:location,windows:[]) }

    func refresh() {
        refreshExternalMonitor()
        diagnostic=MacEnvironment.json(MacEnvironment.diagnostics(spaces:spaces,trusted:trusted))
        do {
            let next=try windows.snapshot()
            if let old=snapshot, old.topology != next.topology { bindings=[]; guidedBindings=[]; guidedBindingArchive=[:]; message="屏幕/桌面拓扑已改变，请重新绑定桌面用途。" }
            snapshot=next
        } catch { snapshot=nil; bindings=[]; message="无法读取 Spaces：\(error)。禁止恢复。" }
        preview=nil; guidedPreview=nil
    }
    func bindCurrent() {
        refresh()
        guard let s=snapshot else { return }
        let displays=s.displays.filter{$0.role==role}
        guard displays.count==1 else { message="请选择已连接且唯一的屏幕角色。"; return }
        let candidates=s.spaces.filter{$0.displayToken==displays[0].token && $0.active && $0.kind == .ordinary}
        let label=desktopLabel.trimmingCharacters(in:.whitespacesAndNewlines)
        guard candidates.count==1, !label.isEmpty else { message="当前必须是普通桌面，且用途名称不能为空。"; return }
        let binding=DesktopBinding(label:label,role:role,spaceID:candidates[0].id,snapshot:s)
        bindings.removeAll{($0.role==role && $0.label==label) || $0.spaceID==binding.spaceID}
        bindings.append(binding); message="已绑定 \(role.rawValue) / \(label)。可手动切换原生桌面后继续绑定。"
    }
    @discardableResult func scan(onlyFixture: Bool? = nil) -> Bool {
        do {
            var next=try windows.scan(onlyPID:(onlyFixture ?? fixtureOnly) ? getpid() : nil)
            if onlyFixture ?? fixtureOnly { next.windows=next.windows.filter{$0.selector.title.hasPrefix("LayoutKeeper Fixture ")} }
            if let old=snapshot, old.topology != next.topology { bindings=[] }
            snapshot=next; preview=nil
            message="读取 \(next.windows.count) 个窗口。AX 可能遗漏非当前桌面窗口；可手动切换桌面分批采集。\n" + windows.issues.joined(separator:"\n")
            return true
        } catch { message="读取未执行：\(error)。本应用没有发起权限请求。"; return false }
    }
    func capture() {
        guard scan() else { return }
        guard let s=snapshot else { return }
        do {
            let (captured,issues)=try Planner.capture(location:location,snapshot:s,bindings:bindings)
            var merged=currentProfile.windows
            for entry in captured.windows { merged.removeAll{entry.selector.matches($0.selector)}; merged.append(entry) }
            profiles[location]=Profile(location:location,windows:merged)
            message="此次采集 \(captured.windows.count) 个窗口；当前地点合计 \(merged.count) 个。\n" + issues.joined(separator:"\n")
        } catch { message="保存采集失败：\(error)" }
    }
    func makePreview() {
        do {
            guard !currentProfile.windows.isEmpty else { message="请先分批采集或加载配置。"; return }
            var s=try windows.scan(onlyPID:fixtureOnly ? getpid() : nil)
            if fixtureOnly { s.windows=s.windows.filter{$0.selector.title.hasPrefix("LayoutKeeper Fixture ")} }
            if let old=snapshot,old.topology != s.topology { bindings=[] }
            snapshot=s
            preview=try Planner.plan(profile:currentProfile,snapshot:s,bindings:bindings,canMoveSpaces:spaces.canMove)
            results=[]; message="预览已生成；跨桌面项目会被阻止。同桌面的普通窗口可申请恢复。"
        } catch { message="无法预览：\(error)"; preview=nil }
    }
    func restore() {
        guard !restoring, let plan=preview else { return }
        let ready=plan.entries.filter{$0.status == .ready}
        guard !ready.isEmpty else { message="没有可恢复窗口。请查看阻塞原因。"; return }
        let alert=NSAlert(); alert.messageText="确认移动以下窗口？"
        alert.informativeText=ready.map { entry in
            let f=entry.targetFrame!
            return "\(entry.saved.selector.bundleID) — \(entry.saved.selector.title) → \(entry.saved.displayRole.rawValue)/\(entry.saved.desktopLabel) (\(Int(f.x)),\(Int(f.y)),\(Int(f.width))×\(Int(f.height)))"
        }.joined(separator:"\n") + "\n只执行预览中的可恢复项目；执行后回读位置、尺寸和桌面。失败可能留下部分位置改变，请检查报告。"
        alert.addButton(withTitle:"批准此预览"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restoring=true
        windows.writesApproved=true
        defer { windows.writesApproved=false; preview=nil; restoring=false }
        results=Restorer.execute(plan,windows:windows,spaces:spaces,approved:true,polls:8,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))})
        message="执行完成，请按逐项回读结果检查。"
    }
    func saveProfile() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="layoutkeeper-\(location).json"; panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try ProfileStore.save(currentProfile,to:url); message="配置已保存到 \(url.path)。配置可能含窗口标题/文档路径，仅保存在所选本地文件。" } catch { message="写入失败：\(error)" }
    }
    func loadProfile() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { let p=try ProfileStore.load(from:url); profiles[p.location]=p; location=p.location; preview=nil; message="已加载 \(p.windows.count) 个窗口；请绑定当前桌面用途。" } catch { message="加载失败：\(error)" }
    }
    func exportDiagnostic() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="layoutkeeper-diagnostic.json"; panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try diagnostic.write(to:url,atomically:true,encoding:.utf8) } catch { message="导出失败：\(error)" }
    }
    func createFixtures() {
        guard fixtures.isEmpty else { return }
        for index in 1...1 {
            var frame=NSRect(x:180+index*40,y:220+index*40,width:520,height:340)
            if emptyWindowTrial != nil,let screen=NSScreen.screens.first(where:{ screen in
                guard let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value)==0
            }) {
                let visible=screen.visibleFrame
                frame=NSRect(x:visible.minX+40,y:visible.minY+40,width:min(520,visible.width-80),height:min(340,visible.height-80))
            }
            let window=NSWindow(contentRect:frame,styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.title="LayoutKeeper Fixture \(index)"; window.isReleasedWhenClosed=false
            window.contentView=NSHostingView(rootView:VStack(spacing:18) { Image(systemName:"rectangle.3.group").font(.system(size:44)); Text("空白演示窗口").font(.title2); Text("先在 LayoutKeeper 保存布局。\n用鼠标移动或调整本窗口，再预览恢复。\n这里没有你的文档。").multilineTextAlignment(.center) }.frame(maxWidth:.infinity,maxHeight:.infinity))
            window.makeKeyAndOrderFront(nil); fixtures.append(window)
        }
        message="已创建 LayoutKeeper Fixture 1 空白测试窗口；未申请权限、未自动移动窗口。"
    }
    func simulation(_ noop: Bool) {
        let backend=DemoBackend(); backend.pretendSuccess=noop
        do { results=Restorer.execute(try backend.plan(),windows:backend,spaces:backend,approved:true); message="模拟结果：仅内存状态，未操作 macOS 窗口。" } catch { message="模拟失败：\(error)" }
    }
    func probeRoundTrip() {
        guard !restoring, let fixture=fixtures.first, fixture.isVisible, let fixtureID=UInt32(exactly:fixture.windowNumber) else { message="请先创建空白测试窗口。"; return }
        refresh()
        guard let s=snapshot,
              let source=try? spaces.membership(windowID:fixtureID), source.count==1,
              s.spaces.contains(where:{$0.id==source[0] && $0.kind == .ordinary}) else { message="测试窗口原桌面未知；探针被阻止。"; return }
        let targets=bindings.filter{$0.role==role && $0.label==desktopLabel && $0.session==s.session && $0.topology==s.topology}
        guard targets.count==1, targets[0].spaceID != source[0],s.spaces.contains(where:{$0.id==targets[0].spaceID && $0.kind == .ordinary}) else { message="请在地点与布局中，将另一个普通桌面绑定为当前选定的屏幕角色和用途。"; return }
        let target=targets[0].spaceID
        let alert=NSAlert(); alert.messageText="批准仅移动 LayoutKeeper Fixture 1 的跨桌面探针？"
        alert.informativeText="只对本应用新建的空白窗口调用仅经过隔离用例验证的 macOS 私有桥接方法：原普通桌面 → \(role.rawValue)/\(desktopLabel)，回读确认后再返回原桌面并回读。不会移动其他应用窗口、切换桌面或调整坐标。若返回失败，空白窗口可能留在目标桌面，可由你手动关闭。"
        alert.addButton(withTitle:"批准隔离往返测试"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restoring=true; defer { restoring=false; preview=nil }
        var dispatchDetail=""
        func dispatch(_ id: UInt64) -> Bool {
            guard fixture.windowNumber==Int(fixtureID),let now=try? windows.snapshot(),now.topology==s.topology,now.session==s.session else { dispatchDetail="窗口已关闭或桌面拓扑已改变"; return false }
            var detail=[CChar](repeating:0,count:512)
            let code=SPDispatchOwnedFixture(fixtureID,id,&detail,512)
            dispatchDetail=String(cString:detail)
            return code==0
        }
        func verify(_ id: UInt64) -> Bool {
            for _ in 0..<20 {
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))
                guard fixture.windowNumber==Int(fixtureID),let now=try? windows.snapshot(),now.topology==s.topology else { return false }
                if (try? spaces.membership(windowID:fixtureID)) == [id] { return true }
            }
            return false
        }
        let moved=dispatch(target) && verify(target)
        if !moved { results=[RestoreResult(title:fixture.title,outcome:.failed,detail:"隔离探针未确认目标桌面成员关系；\(dispatchDetail)。通用后端未启用。")]; message="探针失败或被阻止，请检查空白窗口实际所在桌面。"; return }
        let returned=dispatch(source[0]) && verify(source[0])
        results=[RestoreResult(title:fixture.title,outcome:returned ? .verified : .failed,detail:returned ? "仅空白窗口的桌面往返成员关系已回读验证；不能外推至其他应用或其他 build。" : "到达目标已验证，但返回原桌面未通过；通用后端仍禁用。")]
        message="隔离探针结束。此结果仅覆盖空白原生窗口的 Space 成员关系。"
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model=Model()
    var item: NSStatusItem!; var window: NSWindow!
    var reconnect: ReconnectCoordinator?
    var settingsWindow: NSWindow?
    var previewPanel: NSPanel?
    var onboardingWindow: NSWindow?
    var onboarding: OnboardingController?
    var authorizationTimer: Timer?
    let toasts=ToastCenter()
    let hotkeys=GlobalHotkeys()
    private var liveTimer: Timer?
    private var lastAction: [String:Date]=[:]
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self,andSelector:#selector(handleURL(_:reply:)),forEventClass:AEEventClass(kInternetEventClass),andEventID:AEEventID(kAEGetURL))
    }
    /// layoutkeeper://self-test (and the legacy spaceport://self-test) only opens the self-test confirmation; nothing moves without the user's click.
    @objc func handleURL(_ event: NSAppleEventDescriptor,reply: NSAppleEventDescriptor) {
        guard let text=event.paramDescriptor(forKeyword:AEKeyword(keyDirectObject))?.stringValue,let url=URL(string:text),
              AppIdentity.urlSchemes.contains(url.scheme?.lowercased() ?? ""),url.host?.lowercased()=="self-test" else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { [weak self] in self?.model.beginSelfTest(trigger:"url") }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.configureEmptyWindowTrial()
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image=NSImage(systemSymbolName:"rectangle.3.group",accessibilityDescription:"LayoutKeeper")
        let menu=NSMenu(); menu.autoenablesItems=false; menu.delegate=self
        item.menu=menu
        NSApp.mainMenu=buildMainMenu()
        model.openSettings={ [weak self] tab in self?.showSettings(tab) }
        model.showToast={ [weak self] toast in self?.toasts.show(toast) }
        model.openPreviewPanel={ [weak self] rescan in self?.showPreviewPanel(rescan:rescan) }
        model.requestLiveCheck={ [weak self] in self?.scheduleLiveCheck(after:0.6,force:true) }
        model.openOnboarding={ [weak self] in self?.showOnboarding(.reopened) }
        hotkeys.onPress={ [weak self] action in self?.perform(hotkey:action) }
        model.applyHotkeys={ [weak self] in self?.applyHotkeys() }
        model.suspendHotkeys={ [weak self] suspended in
            guard let self else { return }
            if suspended { self.hotkeys.unregisterAll() } else { self.applyHotkeys() }
        }
        applyHotkeys()
        let hosting=NSHostingView(rootView:MainView(model:model))
        window=NSWindow(contentRect:NSRect(origin:.zero,size:hosting.fittingSize),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="LayoutKeeper"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent=true; window.isMovableByWindowBackground=true
        window.isReleasedWhenClosed=false; window.contentView=hosting; window.center(); window.delegate=self
        // Opening the window from the menu bar or the reconnect prompt must not switch the user's Space.
        window.collectionBehavior=[.moveToActiveSpace]
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            self?.model.refresh(); self?.reconnect?.note(.screens); self?.scheduleLiveCheck(after:1.5); self?.scheduleFirstLayoutReminder()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.model.refresh(); self?.scheduleLiveCheck(after:0.8) }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in self?.reconnect?.note(.wake) }
        model.refresh(); model.loadGuidedProfiles(); model.refreshAuthorization()
        // First launch, or permission missing at launch (e.g. after a rebuild): the guide replaces the main window.
        if let reason=OnboardingPolicy.reasonAtLaunch(completed:Prefs.store?.bool(forKey:OnboardingPolicy.completedKey) ?? false,trusted:model.trusted) {
            showOnboarding(reason)
        } else { show() }
        reconnect=ReconnectCoordinator(model:model,showMain:{ [weak self] in self?.show() })
        let timer=Timer(timeInterval:2,repeats:true) { [weak self] _ in self?.model.refreshAuthorization() }
        authorizationTimer=timer
        RunLoop.main.add(timer,forMode:.common)
        if let index=CommandLine.arguments.firstIndex(of:"--approved-fixture-test"),CommandLine.arguments.count > index+1 {
            let url=URL(fileURLWithPath:CommandLine.arguments[index+1])
            let phaseIndex=CommandLine.arguments.firstIndex(of:"--test-phase")
            let phase=phaseIndex.flatMap { CommandLine.arguments.count > $0+1 ? CommandLine.arguments[$0+1] : nil } ?? "all"
            guard ["all","spaces","ax"].contains(phase) else { NSApplication.shared.terminate(nil); return }
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in
                guard let self else { return }
                FixtureTest(model:self.model,url:url,phase:phase).run()
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            // Opens the confirmation dialog only; the user must still click to start.
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in self?.model.beginSelfTest(trigger:"launch-argument") }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--smoke-report"),CommandLine.arguments.count > index+1 {
            let url=URL(fileURLWithPath:CommandLine.arguments[index+1])
            // Only our own freshly created window is read. No AX scan or write.
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in
                guard let self else { return }
                var report=MacEnvironment.diagnostics(spaces:self.model.spaces)
                report["simpleModeDefault"]=true
                report["recognizedExternalMonitors"]=self.model.externalMonitors.map{["name":$0.identity.name,"hardwareKey":$0.identity.key,"deviceSerialAvailable":$0.identity.identifiesDevice] as [String:Any]}
                report["appWindowVisible"]=self.window.isVisible; report["statusItemCreated"]=self.item.button != nil
                report["ownWindowNumber"]=self.window.windowNumber
                do { let ids=try self.model.spaces.membership(windowID:UInt32(self.window.windowNumber)); report["ownWindowMembership"]=ids; report["ownWindowMembershipStatus"]=ids.isEmpty ? "INCONCLUSIVE: empty membership" : "PASS (read only)" } catch { report["ownWindowMembershipStatus"]="UNAVAILABLE: \(error)" }
                try? MacEnvironment.json(report).write(to:url,atomically:true,encoding:.utf8)
                NSApplication.shared.terminate(nil)
            }
        }
    }
    func applyHotkeys() { model.hotkeyStatus=hotkeys.apply(model.hotkeySettings) }
    func showOnboarding(_ reason: OnboardingReason) {
        onboardingWindow?.close()
        let controller=OnboardingController(model:model,reason:reason)
        controller.onFinish={ [weak self] flow in
            guard let self else { return }
            if flow.marksCompleted { Prefs.store?.set(true,forKey:OnboardingPolicy.completedKey) }
            self.onboardingWindow?.close(); self.onboardingWindow=nil; self.onboarding=nil
            self.show()
        }
        let hosting=NSHostingView(rootView:OnboardingView(controller:controller))
        let w=NSWindow(contentRect:NSRect(origin:.zero,size:hosting.fittingSize),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        w.title="欢迎使用 LayoutKeeper"; w.titleVisibility = .hidden; w.titlebarAppearsTransparent=true; w.isMovableByWindowBackground=true
        w.isReleasedWhenClosed=false; w.contentView=hosting; w.collectionBehavior=[.moveToActiveSpace]; w.delegate=self; w.center()
        onboarding=controller; onboardingWindow=w
        controller.startPolling()
        w.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    /// "下次接上外接屏时提醒我": once the screens have settled, a gentle toast if this monitor has no saved layout.
    private var reminderTimer: Timer?
    func scheduleFirstLayoutReminder() {
        guard Prefs.store?.bool(forKey:FirstLayoutReminder.key) == true else { return }
        reminderTimer?.invalidate()
        let t=Timer(timeInterval:3.5,repeats:false) { [weak self] _ in
            guard let self else { return }
            self.model.refreshExternalMonitor(); self.model.refreshAuthorization()
            guard FirstLayoutReminder.shouldRemind(flag:true,monitorConnected:self.model.currentExternalMonitor != nil,hasLayout:self.model.externalRecord != nil,trusted:self.model.trusted) else { return }
            Prefs.store?.removeObject(forKey:FirstLayoutReminder.key)
            let name=self.model.currentMonitorName ?? "外接屏"
            self.toasts.show(Toast(icon:"square.and.arrow.down",tone:.info,title:"接上了「\(name)」",detail:"摆好窗口后保存一次，以后就能一键恢复",
                                   actions:[Toast.Action(title:"现在保存") { [weak self] in self?.model.quickSave() }],duration:12))
        }
        reminderTimer=t; RunLoop.main.add(t,forMode:.common)
    }
    /// Ignores a repeat of the same action within 0.8 s (a menu key equivalent and the global hotkey can both fire).
    private func debounce(_ id: String) -> Bool {
        let now=Date()
        if let last=lastAction[id],now.timeIntervalSince(last)<0.8 { return false }
        lastAction[id]=now; return true
    }
    func perform(hotkey action: HotkeyAction) {
        guard model.recordingHotkey == nil else { return }
        switch action { case .save: run("save"); case .restore: run("restore"); case .undo: run("undo") }
    }
    @objc func menuAction(_ sender: NSMenuItem) { if let id=sender.representedObject as? String { run(id) } }
    func run(_ id: String) {
        switch id {
        case "save": if debounce(id) { model.quickSave() }
        case "restore": if debounce(id) { model.quickRestore() }
        case "previewRestore": showPreviewPanel(rescan:true)
        case "undo": if debounce(id) { model.quickUndo() }
        case "mode.off": model.autoRestoreMode = .off
        case "mode.ask": model.autoRestoreMode = .ask
        case "mode.auto": model.autoRestoreMode = .auto
        case "mode.forget": if let key=model.currentExternalMonitor?.identity.key { model.monitorPreferences.setRestore(nil,for:key) }
        case "pause.oneHour": model.pausedUntil=AutoRestorePause.oneHour.until(from:Date())
        case "pause.untilTomorrow": model.pausedUntil=AutoRestorePause.untilTomorrow.until(from:Date())
        case "resume": model.pausedUntil=nil
        case "open": show()
        case "settings": showSettings(.general)
        case "advanced": showSettings(.advanced)
        case "quit": NSApplication.shared.terminate(nil)
        default: break
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == item.menu else { return }
        model.refreshExternalMonitor()
        if let until=model.pausedUntil,until<=Date() { model.pausedUntil=nil }
        menu.removeAllItems()
        let optionHeld=NSEvent.modifierFlags.contains(.option)
        StatusMenuBuilder.make(StatusMenuModel.build(model.menuState(optionHeld:optionHeld)),target:self,action:#selector(menuAction(_:))).forEach(menu.addItem)
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true); scheduleLiveCheck(after:0.3,force:true) }
    func windowDidBecomeKey(_ notification: Notification) { if (notification.object as? NSWindow) == window { scheduleLiveCheck(after:0.5) } }
    /// Debounced read-only status check for the main window (only while it is visible).
    func scheduleLiveCheck(after delay: TimeInterval,force: Bool = false) {
        guard force || window?.isVisible == true else { return }
        liveTimer?.invalidate()
        let t=Timer(timeInterval:delay,repeats:false) { [weak self] _ in
            guard let self,self.window.isVisible,!self.model.busy,self.previewPanel?.isVisible != true else { return }
            self.model.refreshExternalMonitor(); self.model.refreshLiveState()
        }
        liveTimer=t; RunLoop.main.add(t,forMode:.common)
    }
    func showPreviewPanel(rescan: Bool) {
        if rescan { model.prepareQuickRestore() }
        if previewPanel == nil {
            let p=NSPanel(contentRect:NSRect(x:0,y:0,width:620,height:560),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
            p.title="恢复预览"; p.titleVisibility = .hidden; p.titlebarAppearsTransparent=true; p.isMovableByWindowBackground=true
            p.isReleasedWhenClosed=false; p.hidesOnDeactivate=false; p.collectionBehavior=[.moveToActiveSpace]; p.delegate=self
            p.contentView=NSHostingView(rootView:QuickRestoreSheet(model:model,onClose:{ [weak self] in self?.previewPanel?.close() }))
            p.center(); previewPanel=p
        }
        model.showingQuickRestore=true
        previewPanel?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboardingWindow,let controller=onboarding,!controller.flow.finished {
            // Closing the guide with × counts as skipping (it re-appears only if permission is missing at launch).
            controller.skip(); return
        }
        if (notification.object as? NSPanel) === previewPanel { model.showingQuickRestore=false; scheduleLiveCheck(after:0.4) }
    }
    @objc func openSettingsGeneral() { showSettings(.general) }
    @objc func openAdvanced() { showSettings(.advanced) }
    func showSettings(_ tab: SettingsTab) {
        model.settingsTab=tab
        if settingsWindow == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:620),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title="LayoutKeeper 设置"; w.isReleasedWhenClosed=false; w.collectionBehavior=[.moveToActiveSpace]
            w.contentView=NSHostingView(rootView:SettingsView(model:model)); w.center(); settingsWindow=w
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    /// The app is an accessory (no Dock icon), but key equivalents like ⌘, and ⌘C still route through the main menu.
    func buildMainMenu() -> NSMenu {
        let main=NSMenu()
        let appItem=NSMenuItem(); let app=NSMenu(); appItem.submenu=app; main.addItem(appItem)
        let settings=NSMenuItem(title:"设置…",action:#selector(openSettingsGeneral),keyEquivalent:","); settings.target=self; app.addItem(settings)
        app.addItem(.separator())
        let close=NSMenuItem(title:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"); app.addItem(close)
        let q=NSMenuItem(title:"退出 LayoutKeeper",action:#selector(quit),keyEquivalent:"q"); q.target=self; app.addItem(q)
        let editItem=NSMenuItem(); let edit=NSMenu(title:"编辑"); editItem.submenu=edit; main.addItem(editItem)
        edit.addItem(NSMenuItem(title:"拷贝",action:#selector(NSText.copy(_:)),keyEquivalent:"c"))
        edit.addItem(NSMenuItem(title:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v"))
        edit.addItem(NSMenuItem(title:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a"))
        return main
    }
    /// Only our own activation re-checks (not every app switch): the check is a read-only scan on the main thread.
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshExternalMonitor(); scheduleLiveCheck(after:0.6) }
    func applicationWillTerminate(_ notification: Notification) { authorizationTimer?.invalidate(); hotkeys.unregisterAll() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}
if let index=CommandLine.arguments.firstIndex(of:"--render-ui-snapshots"),CommandLine.arguments.count>index+1 {
    // Offscreen PNG rendering with sample data; never touches other windows, AX, or saved layouts.
    NSApplication.shared.setActivationPolicy(.prohibited)
    exit(MainActor.assumeIsolated { UISnapshots.run(to:URL(fileURLWithPath:CommandLine.arguments[index+1])) })
}
AppMigration.runAtLaunch()
let application=NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate=Delegate(); application.delegate=delegate
application.run()
