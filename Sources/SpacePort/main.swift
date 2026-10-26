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
    @Published var snapshot: Snapshot?
    @Published var message=lk("先查看诊断；实际窗口测试需批准辅助功能权限。")
    @Published var results: [RestoreResult]=[]
    @Published var fixtureOnly=true
    @Published var restoring=false
    @Published var accessState=ControlAccessState()
    @Published var settingsMessage=""
    let accessMonitor=ControlAccessMonitor()
    var trusted: Bool { accessState.canReadWindows }
    var versionLabel: String {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? lk("开发版本")
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? lk("未打包")
        let url=Bundle.main.bundleURL
        let dev=AppInstallation.isDevelopmentBuild(bundleURL:url) ? " · "+lk("开发构建") : ""
        return lk("版本 %@ (%@) · %@", "\(version)", "\(build)", "\(AppInstallation.location(bundleURL:url))")+dev
    }
    func refreshAuthorization() { accessState=accessMonitor.check() }
    func openControlSettings() {
        let opened=ControlSettings.open(using:{ NSWorkspace.shared.open($0) })
        let panel=ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? lk("设备控制和数据访问") : lk("辅助功能")
        settingsMessage=opened ? lk("请在“隐私与安全性 → %@”允许 LayoutKeeper。应用会自动检查结果。", "\(panel)") : lk("系统设置未能打开。请手动在“隐私与安全性 → %@”允许 LayoutKeeper。", "\(panel)")
    }
    @Published var externalMonitors: [ConnectedMonitor]=[]
    @Published var externalRecord: MonitorLayoutRecord?
    /// Saved-screens sidebar (0.6.0). The connected screen is listed even before its first save.
    @Published var savedScreens: [SavedScreen]=[]
    @Published var selectedScreenKey: String?
    @Published var selectedRecord: MonitorLayoutRecord?
    @Published var screenVersions: [LayoutVersion]=[]
    @Published var namedLayouts: [NamedLayout]=[]
    @Published var previewVersion: LayoutVersion?
    @Published var previewRecord: MonitorLayoutRecord?
    @Published var externalMessage=""
    @Published var externalRestoreResults: [RestoreResult]=[]
    @Published var externalRestoreMessage=""
    @Published var lastRestoreJournal: RestoreJournal?
    var lastRestoreJournalURL: URL?
    /// Windows the last restore could not move (app + reason), for the result notice.
    var lastRestoreFailures: [RestoreFailure]=[]
    /// Apps that failed a restore recently run last next time, so one slow app cannot hold up the others.
    var recentlyFailedBundles: [String:Date]=[:]
    var lastRestorePermits: [SpaceMovePermit]=[]
    var fixtureSpaceJournalURL: URL?
    var fixtureSpacePermits: [SpaceMovePermit]=[]
    var restoreDisplayToken: String?
    var layoutStorageOverride: URL?
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
    /// Sparkle; nil in snapshot rendering and builds without a feed.
    var updater: AppUpdater? { didSet { autoCheckUpdates=updater?.automaticallyChecks ?? true } }
    @Published var autoCheckUpdates=true { didSet { if let updater,updater.automaticallyChecks != autoCheckUpdates { updater.automaticallyChecks=autoCheckUpdates } } }
    @Published var settingsTab=SettingsTab.general
    var openSettings: ((SettingsTab) -> Void)?
    @Published var autoRestoreMode=AutoRestoreMode(rawValue:Prefs.store?.string(forKey:"autoRestoreMode") ?? "") ?? .defaultMode {
        didSet { Prefs.store?.set(autoRestoreMode.rawValue,forKey:"autoRestoreMode") }
    }
    @Published var keepAwakeMode=KeepAwakeMode(rawValue:Prefs.store?.string(forKey:KeepAwakeMode.preferenceKey) ?? "") ?? .defaultMode {
        didSet { Prefs.store?.set(keepAwakeMode.rawValue,forKey:KeepAwakeMode.preferenceKey); refreshKeepAwake(reason:"preference") }
    }
    @Published var keepAwakeVerified=true
    let sleepGuard=SystemSleepGuard()
    private var lastKeepAwakeLog: String?
    func refreshKeepAwake(reason: String) {
        guard !RenderMode.snapshot else { return }
        let res=sleepGuard.apply(mode:keepAwakeMode)
        if keepAwakeVerified != res.verified { keepAwakeVerified=res.verified }
        let summary="mode=\(keepAwakeMode.rawValue) clamshell=\(res.clamshell) verified=\(res.verified) assertions=\(res.activeTypes.sorted())"
        if summary != lastKeepAwakeLog {
            lastKeepAwakeLog=summary
            logRestore("keep-awake: \(summary) (\(reason))")
        }
    }
    @Published var layoutMode=LayoutMode(rawValue:Prefs.store?.string(forKey:LayoutMode.preferenceKey) ?? "") ?? .defaultMode {
        didSet { Prefs.store?.set(layoutMode.rawValue,forKey:LayoutMode.preferenceKey); if oldValue != layoutMode { layoutModeChanged() } }
    }
    /// Notices from shared mode (too few Spaces / Spaces moved to the built-in screen); shown in the main window too.
    @Published var sharedNotice: SharedNotice?
    var pendingSpacesNeeded: Int?
    /// Trigger of the restore in progress; a follow-up restore after auto-adding desktops uses the same trigger.
    var lastRestoreTrigger: RestoreTrigger = .manual
    /// Set by ReconnectCoordinator while an attach session's restore runs: auto-add desktops hands its result back
    /// so the follow-up restore runs inside that session. Captured when the add starts.
    var autoSpacesFollowUp: ((Result<Int,AutoSpacesFailure>) -> Void)?
    /// Set when a restore started an auto-add of desktops (reset by the caller before the restore).
    var autoSpacesStartedByRestore=false
    /// 桌面管理 (shared mode only): add missing Spaces / remove empty migrated Spaces through Mission Control.
    @Published var autoAddSpaces=Prefs.store?.object(forKey:AutoSpaces.addPreferenceKey) as? Bool ?? AutoSpaces.defaultEnabled { didSet { Prefs.store?.set(autoAddSpaces,forKey:AutoSpaces.addPreferenceKey) } }
    /// 0.6.8: no UI changes this any more; the stored value is kept as it was but only counts through `autoRemoveSpacesEffective`.
    let autoRemoveSpacesStored=Prefs.store?.object(forKey:AutoSpaces.removePreferenceKey) as? Bool ?? AutoSpaces.removeDefaultEnabled
    /// The only switch that lets LayoutKeeper delete Spaces after an unplug. Forced off while the feature is hidden.
    var autoRemoveSpacesEffective: Bool { AutoSpaces.removeEffective(stored:autoRemoveSpacesStored) }
    lazy var autoSpaces: AutoSpacesRunner = {
        let runner=AutoSpacesRunner(spaces:spaces)
        runner.openLog={ [weak self] lines in if !lines.isEmpty { self?.logRestore("mission control open: "+lines.joined(separator:" | ")) } }
        return runner
    }()
    /// Brightness / volume control (显示器).
    let displayControl=DisplayControl()
    @Published var missionControlReport=""
    @Published var autoSpacesTrialMessage=""
    /// Snapshot rendering only: pretend the system setting is off to show the hint.
    var snapshotSeparateSpacesOff=false
    @Published var monitorPreferences=Prefs.monitorPreferences() { didSet { Prefs.save(monitorPreferences,key:Prefs.monitorPreferencesKey) } }
    /// 暂停自动恢复 was removed in 0.6.4; any stored pause is cleared at launch so it can never block a restore.
    @Published var pausedUntil: Date?={ Prefs.store?.removeObject(forKey:Prefs.pausedUntilKey); return nil }() {
        didSet { if let pausedUntil { Prefs.store?.set(pausedUntil,forKey:Prefs.pausedUntilKey) } else { Prefs.store?.removeObject(forKey:Prefs.pausedUntilKey) } }
    }
    @Published var hotkeySettings=Prefs.hotkeys() { didSet { Prefs.save(hotkeySettings,key:Prefs.hotkeysKey); applyHotkeys?() } }
    @Published var hotkeyStatus: [HotkeyAction:HotkeyStatus]=[:]
    @Published var recordingHotkey: HotkeyAction?
    /// 显示器排列预设. Changing them re-registers the hotkeys (a preset can carry one).
    @Published var arrangementPresets=Prefs.arrangementPresets() { didSet { Prefs.save(arrangementPresets,key:Prefs.arrangementPresetsKey); applyHotkeys?() } }
    @Published var portArrangementRules=Prefs.portArrangementRules() { didSet { Prefs.save(portArrangementRules,key:Prefs.portArrangementRulesKey) } }
    var lastAutoAppliedPortKey: String?
    @Published var arrangementHotkeyStatus: [String:HotkeyStatus]=[:]
    @Published var recordingPresetHotkey: String?
    /// A switch waiting for 「保留这个排列？」 (blocks restores and other switches until it is kept or reverted).
    @Published var arrangementPreview: ArrangementPreview?
    var arrangementTimer: Timer?
    /// Screen events from LayoutKeeper's own arrangement change are not plug-ins (see ReconnectCoordinator.note).
    var arrangementGuard=SelfArrangementGuard()
    var showArrangementConfirm: ((ArrangementPreview) -> Void)?
    var hideArrangementConfirm: (() -> Void)?
    /// An attach (plug-in / wake) restore is pending or running.
    var attachInProgress: () -> Bool={ false }
    /// Sample displays for snapshot rendering only (the real list is read from CoreGraphics).
    var snapshotDisplays: [LiveDisplay]=[]
    /// Read-only plan for the main window's "differs / matches" state; computed with its own AX reader.
    @Published var livePlan: QuickRestorePlan?
    var livePlanKey: String?
    @Published var lastRestoreSummary: RestoreSummary?
    var notify: ((UserNotice) -> Void)?
    /// Latest notice macOS would not show as a banner; listed in the menu-bar menu until clicked or replaced.
    @Published var undeliveredNotice: UserNotice?
    @Published var notificationPermission: NotificationPermission = .notDetermined
    var openPreviewPanel: ((Bool) -> Void)?
    var applyHotkeys: (() -> Void)?
    var openOnboarding: (() -> Void)?
    var suspendHotkeys: ((Bool) -> Void)?
    var requestLiveCheck: (() -> Void)?
    /// Separate reader so background status checks never replace the handles a restore/undo relies on.
    /// 0.6.9: continuous record of the external windows (frozen at unplug) and the record an attach restores from.
    let liveRecorder=LiveRecorder()
    var arrival: ArrivalLayout?
    /// Where each window of `quickRecord` came from (live record / saved layout), for the planner.
    var quickContext: RestoreContext?
    lazy var statusWindows: AXWindows={ let w=AXWindows(spaces:spaces); w.remoteSearchTotal=1.5; w.remoteSearchPerApp=0.4; return w }()

    func refresh() {
        refreshExternalMonitor()
        diagnostic=MacEnvironment.json(MacEnvironment.diagnostics(spaces:spaces,trusted:trusted))
        do {
            let next=try windows.snapshot()
                        snapshot=next
        } catch { snapshot=nil; message=lk("无法读取 Spaces：%@。禁止恢复。", "\(error)") }
    }
    func exportDiagnostic() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="layoutkeeper-diagnostic.json"; panel.allowedContentTypes=[.json]
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try diagnostic.write(to:url,atomically:true,encoding:.utf8) } catch { message=lk("导出失败：%@", "\(error)") }
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
            window.contentView=NSHostingView(rootView:VStack(spacing:18) { Image(systemName:"rectangle.3.group").font(.system(size:44)); Text(lk("空白演示窗口")).font(.title2); Text(lk("先在 LayoutKeeper 保存布局。\n用鼠标移动或调整本窗口，再预览恢复。\n这里没有你的文档。")).multilineTextAlignment(.center) }.frame(maxWidth:.infinity,maxHeight:.infinity))
            window.makeKeyAndOrderFront(nil); fixtures.append(window)
        }
        message=lk("已创建 LayoutKeeper Fixture 1 空白测试窗口；未申请权限、未自动移动窗口。")
    }
    func simulation(_ noop: Bool) {
        let backend=DemoBackend(); backend.pretendSuccess=noop
        do { results=Restorer.execute(try backend.plan(),windows:backend,spaces:backend,approved:true); message=lk("模拟结果：仅内存状态，未操作 macOS 窗口。") } catch { message=lk("模拟失败：%@", "\(error)") }
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
    let notifier=SystemNotifier()
    var updater: AppUpdater?
    let hotkeys=GlobalHotkeys()
    let arrangementPanel=ArrangementConfirmPanel()
    private var liveTimer: Timer?
    private var lastAction: [String:Date]=[:]
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so a notification click that launched the app is delivered to the notifier.
        notifier.showMain={ [weak self] in self?.showFromNotification() }
        notifier.log={ [weak self] line in self?.model.logRestore(line) }
        notifier.onMenuFallback={ [weak self] notice in self?.model.undeliveredNotice=notice }
        notifier.onPermission={ [weak self] p in self?.model.notificationPermission=p; self?.model.logRestore("notifications: permission=\(p.rawValue)") }
        notifier.start()
        NSAppleEventManager.shared().setEventHandler(self,andSelector:#selector(handleURL(_:reply:)),forEventClass:AEEventClass(kInternetEventClass),andEventID:AEEventID(kAEGetURL))
    }
    /// layoutkeeper://self-test (and the legacy spaceport://self-test) only opens the self-test confirmation; nothing moves without the user's click.
    @objc func handleURL(_ event: NSAppleEventDescriptor,reply: NSAppleEventDescriptor) {
        guard let text=event.paramDescriptor(forKeyword:AEKeyword(keyDirectObject))?.stringValue,let url=URL(string:text),
              AppIdentity.urlSchemes.contains(url.scheme?.lowercased() ?? ""),url.host?.lowercased()=="self-test" else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { [weak self] in self?.model.beginSelfTest(trigger:"url") }
    }
    let spaceWatcher=SharedSpaceWatcher()
    lazy var displayCoordinator=DisplayControlCoordinator(control:model.displayControl)
    func applicationDidFinishLaunching(_ notification: Notification) {
        MonitorRecognition.layoutMode=model.layoutMode
        model.configureEmptyWindowTrial()
        model.migrateArrangementPresets()
        updater=AppUpdater.makeIfConfigured(); model.updater=updater
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image=NSImage(systemSymbolName:"rectangle.3.group",accessibilityDescription:"LayoutKeeper")
        let menu=NSMenu(); menu.autoenablesItems=false; menu.delegate=self
        item.menu=menu
        NSApp.mainMenu=buildMainMenu()
        model.openSettings={ [weak self] tab in self?.showSettings(tab) }
        model.notify={ [weak self] notice in self?.notifier.show(notice) }
        model.openPreviewPanel={ [weak self] rescan in self?.showPreviewPanel(rescan:rescan) }
        model.requestLiveCheck={ [weak self] in self?.scheduleLiveCheck(after:0.6,force:true) }
        model.openOnboarding={ [weak self] in self?.showOnboarding(.reopened) }
        hotkeys.onPress={ [weak self] action in self?.perform(hotkey:action) }
        hotkeys.onPresetPress={ [weak self] id in
            guard let self,self.model.recordingHotkey == nil,self.model.recordingPresetHotkey == nil,self.debounce("arrange.\(id)") else { return }
            self.model.applyArrangement(id,source:"hotkey")
        }
        model.showArrangementConfirm={ [weak self] preview in
            self?.arrangementPanel.show(preview,keep:{ self?.model.keepArrangement() },revert:{ self?.model.revertArrangement(reason:"user") })
        }
        model.hideArrangementConfirm={ [weak self] in self?.arrangementPanel.close() }
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
            self?.model.arrangementScreensChanged()
            self?.model.applyPortArrangementIfNeeded()
            self?.model.refreshKeepAwake(reason:"screens-changed")
            self?.model.liveRecorder.screensChanged(); self?.spaceWatcher.screensChanged(); self?.model.refresh(); self?.reconnect?.note(.screens); self?.scheduleLiveCheck(after:1.5); self?.scheduleFirstLayoutReminder()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.model.refresh(); self?.scheduleLiveCheck(after:0.8); self?.model.liveRecorder.kick(after:2,reason:"desk switch") }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            if let m=self?.model,m.keepAwakeMode != .off { _=m.sleepGuard.declareUserActivity(); m.refreshKeepAwake(reason:"system-wake") }
            self?.model.liveRecorder.screensChanged(); self?.model.liveRecorder.woke(); self?.reconnect?.note(.wake)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.screensDidWakeNotification,object:nil,queue:.main) { [weak self] _ in
            self?.model.refreshKeepAwake(reason:"screens-wake")
            self?.model.liveRecorder.screensChanged(); self?.model.liveRecorder.woke(); self?.reconnect?.note(.wake)
        }
        // Sleep (system or display-only): whatever happens to the screens before wake is not recorded (a scan in flight is void).
        for sleepName in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName:sleepName,object:nil,queue:.main) { [weak self] notif in
                // An unconfirmed arrangement switch never survives sleep.
                self?.model.revertArrangement(reason:"sleep")
                self?.model.liveRecorder.screensChanged()
                if notif.name == NSWorkspace.screensDidSleepNotification,let m=self?.model,m.keepAwakeMode != .off {
                    let plan=KeepAwakePolicy.plan(mode:m.keepAwakeMode,clamshell:SystemSleepGuard.clamshellState())
                    if plan.wakeDisplayOnSleepEvent {
                        _=m.sleepGuard.declareUserActivity()
                        m.logRestore("keep-awake: declared user activity on display sleep to prevent clamshell/display sleep")
                    }
                    m.refreshKeepAwake(reason:"screens-sleep")
                }
            }
        }
        model.refresh(); model.refreshAuthorization(); model.refreshKeepAwake(reason:"launch")
        // First launch, or permission missing at launch (e.g. after a rebuild): the guide replaces the main window.
        if let reason=OnboardingPolicy.reasonAtLaunch(completed:Prefs.store?.bool(forKey:OnboardingPolicy.completedKey) ?? false,trusted:model.trusted) {
            showOnboarding(reason)
        } else { show() }
        reconnect=ReconnectCoordinator(model:model,showMain:{ [weak self] in self?.show() })
        model.logSession("app launch")
        spaceWatcher.start(model:model)
        model.liveRecorder.attachActive={ [weak self] in self?.reconnect?.attachActive ?? false }
        model.attachInProgress={ [weak self] in self?.reconnect?.attachActive ?? false }
        model.liveRecorder.start(model:model)
        displayCoordinator.start(trusted:{ AXIsProcessTrusted() })
        let timer=Timer(timeInterval:2,repeats:true) { [weak self] _ in
            self?.model.refreshAuthorization()
            self?.model.refreshKeepAwake(reason:"periodic")
            self?.displayCoordinator.evaluate(trusted:AXIsProcessTrusted())
        }
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
    func applyHotkeys() {
        let result=hotkeys.apply(model.hotkeySettings,presets:model.arrangementPresets)
        model.hotkeyStatus=result.actions; model.arrangementHotkeyStatus=result.presets
    }
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
        w.title=lk("欢迎使用 LayoutKeeper"); w.titleVisibility = .hidden; w.titlebarAppearsTransparent=true; w.isMovableByWindowBackground=true
        w.isReleasedWhenClosed=false; w.contentView=hosting; w.collectionBehavior=[.moveToActiveSpace]; w.delegate=self; w.center()
        onboarding=controller; onboardingWindow=w
        controller.startPolling()
        w.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    /// "下次接上外接屏时提醒我": once the screens have settled, a gentle notification if this monitor has no saved layout.
    private var reminderTimer: Timer?
    func scheduleFirstLayoutReminder() {
        guard Prefs.store?.bool(forKey:FirstLayoutReminder.key) == true else { return }
        reminderTimer?.invalidate()
        let t=Timer(timeInterval:3.5,repeats:false) { [weak self] _ in
            guard let self else { return }
            self.model.refreshExternalMonitor(); self.model.refreshAuthorization()
            guard FirstLayoutReminder.shouldRemind(flag:true,monitorConnected:self.model.currentExternalMonitor != nil,hasLayout:self.model.externalRecord != nil,trusted:self.model.trusted) else { return }
            Prefs.store?.removeObject(forKey:FirstLayoutReminder.key)
            let name=self.model.currentMonitorName ?? lk("外接屏")
            self.notifier.show(UserNotice(title:lk("接上了「%@」", "\(name)"),detail:lk("摆好窗口后保存一次，以后就能一键恢复"),
                                   actions:[UserNotice.Action(.saveNow) { [weak self] in self?.model.quickSave() }],duration:12))
        }
        reminderTimer=t; RunLoop.main.add(t,forMode:.common)
    }
    /// Ignores a repeat of the same action within 0.8 s (a menu key equivalent and the global hotkey can both fire).
    func debounce(_ id: String) -> Bool {
        let now=Date()
        if let last=lastAction[id],now.timeIntervalSince(last)<0.8 { return false }
        lastAction[id]=now; return true
    }
    func perform(hotkey action: HotkeyAction) {
        guard model.recordingHotkey == nil,model.recordingPresetHotkey == nil else { return }
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
        case "keepAwake.off": model.keepAwakeMode = .off
        case "keepAwake.systemOnly": model.keepAwakeMode = .systemOnly
        case "keepAwake.systemAndDisplay": model.keepAwakeMode = .systemAndDisplay
        case "open": show()
        case "notice":
            let notice=model.undeliveredNotice; model.undeliveredNotice=nil
            if let open=notice?.open { open() } else { show() }
        case "settings": showSettings(.general)
        case "checkUpdates": updater?.checkForUpdates()
        case "quit": NSApplication.shared.terminate(nil)
        case "arrange.port.bind": if debounce(id) { model.bindCurrentPortArrangement() }
        case "arrange.port.unbind": if debounce(id) { model.unbindCurrentPortArrangement() }
        case "arrange.save": model.saveCurrentArrangement()
        case "arrange.manage": showSettings(.displays)
        case let quick where quick.hasPrefix(StatusMenuModel.quickArrangementPrefix):
            if debounce(quick),let edge=ArrangementEdge(rawValue:String(quick.dropFirst(StatusMenuModel.quickArrangementPrefix.count))) {
                model.applyQuickArrangement(edge:edge,source:"menu")
            }
        case let preset where preset.hasPrefix(StatusMenuModel.arrangementPrefix):
            if debounce(preset) { model.applyArrangement(String(preset.dropFirst(StatusMenuModel.arrangementPrefix.count)),source:"menu") }
        case let layout where layout.hasPrefix("layout."): if let i=Int(layout.dropFirst(7)),debounce("layout") { model.applyConnectedLayout(at:i) }
        default: break
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == item.menu else { return }
        model.refreshExternalMonitor()
        if let until=model.pausedUntil,until<=Date() { model.pausedUntil=nil }
        menu.removeAllItems()
        let optionHeld=NSEvent.modifierFlags.contains(.option)
        if model.displayControl.showInMenu {
            model.displayControl.refresh()
            let item=NSMenuItem(); let host=NSHostingView(rootView:DisplayMenuSection(control:model.displayControl))
            host.frame=NSRect(origin:.zero,size:host.fittingSize); item.view=host
            menu.addItem(item); menu.addItem(.separator())
        }
        StatusMenuBuilder.make(StatusMenuModel.build(model.menuState(optionHeld:optionHeld)),target:self,action:#selector(menuAction(_:))).forEach(menu.addItem)
    }
    /// A notification click can arrive while the app is still launching: wait for the main window.
    func showFromNotification() {
        guard window != nil else { DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in self?.showFromNotification() }; return }
        if let w=onboardingWindow,w.isVisible { w.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true); return }
        show()
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
            p.title=lk("恢复预览"); p.titleVisibility = .hidden; p.titlebarAppearsTransparent=true; p.isMovableByWindowBackground=true
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
    func showSettings(_ tab: SettingsTab) {
        model.settingsTab=tab
        if settingsWindow == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:620),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            w.title=lk("LayoutKeeper 设置"); w.isReleasedWhenClosed=false; w.collectionBehavior=[.moveToActiveSpace]
            w.contentView=NSHostingView(rootView:SettingsView(model:model)); w.center(); settingsWindow=w
        }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true)
    }
    /// The app is an accessory (no Dock icon), but key equivalents like ⌘, and ⌘C still route through the main menu.
    func buildMainMenu() -> NSMenu {
        let main=NSMenu()
        let appItem=NSMenuItem(); let app=NSMenu(); appItem.submenu=app; main.addItem(appItem)
        let settings=NSMenuItem(title:lk("设置…"),action:#selector(openSettingsGeneral),keyEquivalent:","); settings.target=self; app.addItem(settings)
        let updates=NSMenuItem(title:lk("检查更新…"),action:#selector(checkForUpdates),keyEquivalent:""); updates.target=self; app.addItem(updates)
        app.addItem(.separator())
        let close=NSMenuItem(title:lk("关闭窗口"),action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"); app.addItem(close)
        let q=NSMenuItem(title:lk("退出 LayoutKeeper"),action:#selector(quit),keyEquivalent:"q"); q.target=self; app.addItem(q)
        let editItem=NSMenuItem(); let edit=NSMenu(title:lk("编辑")); editItem.submenu=edit; main.addItem(editItem)
        edit.addItem(NSMenuItem(title:lk("拷贝"),action:#selector(NSText.copy(_:)),keyEquivalent:"c"))
        edit.addItem(NSMenuItem(title:lk("粘贴"),action:#selector(NSText.paste(_:)),keyEquivalent:"v"))
        edit.addItem(NSMenuItem(title:lk("全选"),action:#selector(NSText.selectAll(_:)),keyEquivalent:"a"))
        return main
    }
    /// Only our own activation re-checks (not every app switch): the check is a read-only scan on the main thread.
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshExternalMonitor(); notifier.refreshPermission(); scheduleLiveCheck(after:0.6) }
    func applicationWillTerminate(_ notification: Notification) {
        // macOS undoes an app-only preview itself when we exit; revert explicitly too, so the log says so.
        model.revertArrangement(reason:"quit")
        model.sleepGuard.releaseAll()
        authorizationTimer?.invalidate(); hotkeys.unregisterAll(); displayCoordinator.stop() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    @objc func checkForUpdates() { updater?.checkForUpdates() }
}
// Developer check of brightness hardware (DDC +1/restore, built-in set-same/restore). Requires LAYOUTKEEPER_DEV_DISPLAY_TEST=1.
if let index=CommandLine.arguments.firstIndex(of:"--test-display-control"),CommandLine.arguments.count>index+1,
   ProcessInfo.processInfo.environment["LAYOUTKEEPER_DEV_DISPLAY_TEST"]=="1" {
    var log=[String](); let t0=Date()
    func L(_ s: String) { log.append(String(format:"%6.3f ",Date().timeIntervalSince(t0))+s) }
    for id in DisplayControl.onlineDisplays() {
        let name=DisplayControl.name(id)
        if CGDisplayIsBuiltin(id) != 0 {
            guard let b=BuiltInBrightness.get(id) else { L("\(name): built-in brightness unreadable"); continue }
            L("\(name): built-in brightness=\(b)")
            let ok=BuiltInBrightness.set(id,b); usleep(300000)
            L("  set same value ok=\(ok) readback=\(BuiltInBrightness.get(id) ?? -1)")
            if let now=BuiltInBrightness.get(id),abs(now-b)>0.0005 { BuiltInBrightness.set(id,b); usleep(300000); L("  restored -> \(BuiltInBrightness.get(id) ?? -1)") }
            continue
        }
        let svcs=DDCService.externalServices()
        guard svcs.count==1,let s=svcs.first,let b=s.readVCP(DDCPacket.brightness) else { L("\(name): DDC unavailable (services=\(svcs.count))"); continue }
        L("\(name): DDC brightness=\(b.current)/\(b.max)")
        let target=UInt16(b.current<b.max ? b.current+1 : b.current-1)
        L("  write \(target) ok=\(s.writeVCP(DDCPacket.brightness,target))"); usleep(400000)
        L("  readback=\(s.readVCP(DDCPacket.brightness).map{ "\($0.current)" } ?? "nil")")
        L("  restore \(b.current) ok=\(s.writeVCP(DDCPacket.brightness,UInt16(b.current)))"); usleep(400000)
        let fin=s.readVCP(DDCPacket.brightness)
        L("  final=\(fin.map{ "\($0.current)" } ?? "nil") \(fin?.current==b.current ? "RESTORED" : "MISMATCH")")
    }
    try? log.joined(separator:"\n").write(toFile:CommandLine.arguments[index+1],atomically:true,encoding:.utf8)
    exit(0)
}
if let index=CommandLine.arguments.firstIndex(of:"--render-brightness-mockups"),CommandLine.arguments.count>index+1 {
    NSApplication.shared.setActivationPolicy(.prohibited)
    exit(MainActor.assumeIsolated { BrightnessMockups.run(to:URL(fileURLWithPath:CommandLine.arguments[index+1])) })
}
if let index=CommandLine.arguments.firstIndex(of:"--render-ui-snapshots"),CommandLine.arguments.count>index+1 {
    // Offscreen PNG rendering with sample data; never touches other windows, AX, or saved layouts.
    NSApplication.shared.setActivationPolicy(.prohibited)
    exit(MainActor.assumeIsolated { UISnapshots.run(to:URL(fileURLWithPath:CommandLine.arguments[index+1])) })
}
if CommandLine.arguments.contains("--update-check-and-install") {
    let app=NSApplication.shared; app.setActivationPolicy(.prohibited)
    let driver=HeadlessUpdateDriver()
    DispatchQueue.main.async { driver.start() }
    DispatchQueue.main.asyncAfter(deadline:.now()+120) { HeadlessUpdateDriver.log("timed out"); exit(5) }
    app.run(); exit(0)
}
if let index=CommandLine.arguments.firstIndex(of:"--dump-mission-control"),CommandLine.arguments.count>index+1 {
    NSApplication.shared.setActivationPolicy(.accessory)
    MissionControlProbe.run(out:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0)
}
// Developer-only: changes Spaces, so it also requires LAYOUTKEEPER_DEV_SPACE_TEST=1 in the environment.
if let index=CommandLine.arguments.firstIndex(of:"--test-add-remove-space"),CommandLine.arguments.count>index+1,
   ProcessInfo.processInfo.environment["LAYOUTKEEPER_DEV_SPACE_TEST"]=="1" {
    NSApplication.shared.setActivationPolicy(.accessory)
    AddRemoveSpaceTest.run(out:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0)
}
if ProcessInfo.processInfo.environment["LAYOUTKEEPER_DEV_DIAG"]=="1" {
    NSApplication.shared.setActivationPolicy(.accessory)
    let args=CommandLine.arguments
    if let i=args.firstIndex(of:"--test-chrome-profiles"),args.count>i+1 { DevDiagnostics.chromeProfiles(out:URL(fileURLWithPath:args[i+1])); exit(0) }
    if let i=args.firstIndex(of:"--restore-harness"),args.count>i+1 { DevDiagnostics.restoreHarness(out:URL(fileURLWithPath:args[i+1])); exit(0) }
    if let i=args.firstIndex(of:"--test-notification"),args.count>i+1 { SystemNotifier.selfCheck(out:URL(fileURLWithPath:args[i+1])); exit(0) }
    if args.contains("--close-test-windows") { DevDiagnostics.closeTestWindows(); exit(0) }
    if let i=args.firstIndex(of:"--dry-run-plan"),args.count>i+2 { DevDiagnostics.dryRun(layout:URL(fileURLWithPath:args[i+1]),out:URL(fileURLWithPath:args[i+2])); exit(0) }
}
AppMigration.runAtLaunch()
let application=NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate=Delegate(); application.delegate=delegate
application.run()
