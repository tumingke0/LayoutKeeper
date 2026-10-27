// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

/// One controllable display.
struct ControlledDisplay: Identifiable, Equatable {
    enum Method: Equatable { case builtIn, ddc, software }
    var id: CGDirectDisplayID
    var name: String
    var method: Method
    var brightness: Double
    var ddcMax=100
    var badge: (String,Tone) {
        switch method { case .builtIn: return (lk("内建"),.neutral); case .ddc: return ("DDC",.success); case .software: return (lk("软件调暗"),.warning) }
    }
    static func == (a: ControlledDisplay,b: ControlledDisplay) -> Bool {
        a.id==b.id && a.name==b.name && a.method==b.method && a.brightness==b.brightness
    }
}

/// Brightness for every display: DDC for external monitors (software dimming when DDC fails), DisplayServices for the
/// built-in screen. DDC I/O runs on a serial queue; writes are rate limited and coalesced (latest value wins).
/// The volume keys change the Mac's system output volume (`SystemVolume`), never a monitor's DDC volume.
final class DisplayControl: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay]=[]
    @Published var showInMenu: Bool { didSet { defaults?.set(showInMenu,forKey:DisplayControlPrefs.showInMenu) } }
    @Published var brightnessKeys: Bool { didSet { defaults?.set(brightnessKeys,forKey:DisplayControlPrefs.brightnessKeys); onKeySettingsChanged?() } }
    @Published var volumeKeys: Bool { didSet { defaults?.set(volumeKeys,forKey:DisplayControlPrefs.volumeKeys); onKeySettingsChanged?() } }
    @Published var softwareFallback: Bool { didSet { defaults?.set(softwareFallback,forKey:DisplayControlPrefs.softwareFallback); refresh() } }
    @Published var ddcDisabled: Set<String> { didSet { defaults?.set(Array(ddcDisabled),forKey:DisplayControlPrefs.ddcDisabled); refresh() } }
    @Published var syncWithBuiltIn: Bool {
        didSet {
            defaults?.set(syncWithBuiltIn,forKey:DisplayControlPrefs.syncWithBuiltIn)
            if !syncWithBuiltIn { lastSyncedBuiltIn=nil }
            onSyncSettingsChanged?()
        }
    }
    /// Names of running apps that also grab the brightness keys (BetterDisplay, MonitorControl, Lunar).
    @Published var conflicts: [String]=[]
    @Published var keyTapActive=false
    @Published var keyTapError: String?
    var onKeySettingsChanged: (() -> Void)?
    var onSyncSettingsChanged: (() -> Void)?
    var showHUD: ((ControlledDisplay,BrightnessHUD.Kind) -> Void)?
    /// Volume HUD: output device name, level, muted, and the screen under the mouse to show it on.
    var showVolumeHUD: ((String,Double,Bool,CGDirectDisplayID?) -> Void)?

    private let defaults: UserDefaults?
    private let io=DispatchQueue(label:"layoutkeeper.ddc")
    private var services: [CGDirectDisplayID:DDCService]=[:]
    private var limiters: [String:WriteLimiter]=[:]
    private var pending: [String:(DDCService,UInt8,UInt16)]=[:]
    private var draining: Set<String>=[]
    private var refreshing=false
    private var lastSyncedBuiltIn: Double?

    init(defaults: UserDefaults?=Prefs.store) {
        self.defaults=defaults
        func b(_ k: String,_ d: Bool) -> Bool { defaults?.object(forKey:k) == nil ? d : (defaults?.bool(forKey:k) ?? d) }
        showInMenu=b(DisplayControlPrefs.showInMenu,true)
        brightnessKeys=b(DisplayControlPrefs.brightnessKeys,true)
        volumeKeys=b(DisplayControlPrefs.volumeKeys,true)
        softwareFallback=b(DisplayControlPrefs.softwareFallback,true)
        ddcDisabled=Set(defaults?.stringArray(forKey:DisplayControlPrefs.ddcDisabled) ?? [])
        syncWithBuiltIn=b(DisplayControlPrefs.syncWithBuiltIn,false)
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids=[CGDirectDisplayID](repeating:0,count:16); var n: UInt32=0
        CGGetOnlineDisplayList(16,&ids,&n)
        return Array(ids.prefix(Int(n))).filter { CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0)==kCGNullDirectDisplay }
    }
    static func name(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==id }?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? lk("内建显示屏") : lk("显示器"))
    }
    static func key(_ id: CGDirectDisplayID) -> String { "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))" }
    var displayUnderMouse: ControlledDisplay? {
        let p=NSEvent.mouseLocation
        guard let screen=NSScreen.screens.first(where:{ NSMouseInRect(p,$0.frame,false) }),
              let n=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return displays.first }
        return displays.first { $0.id==n.uint32Value } ?? displays.first
    }

    /// Re-reads every display (DDC reads off the main thread). Software-dimmed displays keep their last level.
    func refresh() {
        guard !RenderMode.snapshot,!refreshing else { return }
        refreshing=true
        let previous=displays, fallback=softwareFallback, disabled=ddcDisabled
        io.async { [weak self] in
            let ids=Self.onlineDisplays()
            let externals=ids.filter { CGDisplayIsBuiltin($0)==0 }
            let svcs=DDCService.externalServices()
            var map=[CGDirectDisplayID:DDCService]()
            if svcs.count==externals.count { for (i,id) in externals.enumerated() { map[id]=svcs[i] } }
            var out=[ControlledDisplay]()
            for id in ids {
                let name=Self.name(id)
                if CGDisplayIsBuiltin(id) != 0 {
                    if let b=BuiltInBrightness.get(id) { out.append(ControlledDisplay(id:id,name:name,method:.builtIn,brightness:b)) }
                    continue
                }
                if !disabled.contains(Self.key(id)),let s=map[id],let b=s.readVCP(DDCPacket.brightness) {
                    out.append(ControlledDisplay(id:id,name:name,method:.ddc,brightness:BrightnessStep.fromDDC(b.current,max:b.max),ddcMax:b.max))
                } else if fallback {
                    map[id]=nil
                    out.append(ControlledDisplay(id:id,name:name,method:.software,brightness:previous.first{ $0.id==id && $0.method == .software }?.brightness ?? 1))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.services=map; self.displays=out; self.refreshing=false
                if self.syncWithBuiltIn,!SystemSleepGuard.clamshellState(),let b=out.first(where:{ $0.method == .builtIn })?.brightness {
                    if self.lastSyncedBuiltIn == nil { self.lastSyncedBuiltIn=b }
                } else {
                    self.lastSyncedBuiltIn=nil
                }
                if !fallback { SoftwareDimming.restoreAll() }
            }
        }
    }

    private func update(_ id: CGDirectDisplayID,_ change: (inout ControlledDisplay) -> Void) -> ControlledDisplay? {
        guard let i=displays.firstIndex(where:{ $0.id==id }) else { return nil }
        change(&displays[i]); return displays[i]
    }
    func setBrightness(_ id: CGDirectDisplayID,_ v: Double,hud: Bool=false) {
        let prevBuiltIn=displays.first(where:{ $0.id==id && $0.method == .builtIn })?.brightness
        guard let d=update(id,{ $0.brightness=min(1,max(0,v)) }) else { return }
        switch d.method {
        case .builtIn:
            BuiltInBrightness.set(id,d.brightness)
            if syncWithBuiltIn {
                let clamshell=SystemSleepGuard.clamshellState()
                let externals=displays.filter{ $0.method != .builtIn }.map{ (id:$0.id,brightness:$0.brightness) }
                let result=BuiltInBrightnessSync.evaluate(
                    enabled:syncWithBuiltIn,
                    clamshell:clamshell,
                    previousBuiltIn:lastSyncedBuiltIn ?? prevBuiltIn,
                    currentBuiltIn:d.brightness,
                    externalBrightnesses:externals
                )
                lastSyncedBuiltIn=result.baseline
                for u in result.updates {
                    setBrightness(u.id,u.newBrightness,hud:false)
                }
            }
        case .software: SoftwareDimming.set(id,d.brightness)
        case .ddc: if let s=services[id] { enqueue(s,id,DDCPacket.brightness,BrightnessStep.toDDC(d.brightness,max:d.ddcMax)) }
        }
        if hud { showHUD?(d,.brightness) }
    }
    func resetSyncBaseline() {
        lastSyncedBuiltIn=nil
    }
    func loadDisplaysForTest(_ list: [ControlledDisplay]) {
        displays=list
        lastSyncedBuiltIn=nil
    }
    func pollBuiltInBrightnessForSync() {
        guard syncWithBuiltIn,!RenderMode.snapshot,!refreshing else { return }
        guard !SystemSleepGuard.clamshellState() else {
            lastSyncedBuiltIn=nil
            return
        }
        guard let builtIn=displays.first(where:{ $0.method == .builtIn }),
              displays.contains(where:{ $0.method != .builtIn }),
              let now=BuiltInBrightness.get(builtIn.id) else {
            lastSyncedBuiltIn=nil
            return
        }
        let clamped=min(1,max(0,now))
        if abs(clamped-builtIn.brightness) >= 0.01 {
            _=update(builtIn.id,{ $0.brightness=clamped })
        }
        let externals=displays.filter{ $0.method != .builtIn }.map{ (id:$0.id,brightness:$0.brightness) }
        let result=BuiltInBrightnessSync.evaluate(
            enabled:syncWithBuiltIn,
            clamshell:false,
            previousBuiltIn:lastSyncedBuiltIn,
            currentBuiltIn:clamped,
            externalBrightnesses:externals
        )
        lastSyncedBuiltIn=result.baseline
        for u in result.updates {
            setBrightness(u.id,u.newBrightness,hud:false)
        }
    }
    /// Volume / mute key on the system output. Returns false (key goes to macOS) when the device can't take it.
    func handleSystemVolume(_ key: MediaKey,fine: Bool) -> Bool {
        let output=SystemVolume.defaultOutput()
        guard VolumeKeyRouting.route(key,enabled:volumeKeys,outputVolumeSettable:output?.volumeSettable == true,outputMuteSettable:output?.muteSettable == true) == .systemOutput,
              let output else { return false }
        let screen=displayUnderMouse?.id
        let name=output.name.isEmpty ? lk("系统音量") : output.name
        if key == .mute {
            let muted = !(SystemVolume.muted(output.device) ?? false)
            guard SystemVolume.setMuted(output.device,muted) else { return false }
            showVolumeHUD?(name,SystemVolume.volume(output.device) ?? 0,muted,screen)
            return true
        }
        guard let current=SystemVolume.volume(output.device) else { return false }
        let next=BrightnessStep.next(current,up:key == .volumeUp,fine:fine,coarse:BrightnessStep.volumeCoarse)
        guard SystemVolume.setVolume(output.device,next) else { return false }
        // Like macOS: changing the level unmutes (and volume down to 0 leaves it at 0, not muted).
        if output.muteSettable,SystemVolume.muted(output.device) == true { SystemVolume.setMuted(output.device,false) }
        showVolumeHUD?(name,SystemVolume.volume(output.device) ?? next,false,screen)
        return true
    }
    /// Coalesced, rate-limited DDC write: only the latest value per (display, feature) is sent, ≥60 ms apart.
    private func enqueue(_ s: DDCService,_ id: CGDirectDisplayID,_ code: UInt8,_ value: UInt16) {
        let k="\(id)-\(code)"
        pending[k]=(s,code,value)
        guard !draining.contains(k) else { return }
        draining.insert(k)
        drain(k)
    }
    private func drain(_ k: String) {
        guard let job=pending.removeValue(forKey:k) else { draining.remove(k); return }
        let wait=(limiters[k] ?? WriteLimiter()).delay(now:Date())
        io.asyncAfter(deadline:.now()+wait) { [weak self] in
            job.0.writeVCP(job.1,job.2)
            DispatchQueue.main.async {
                guard let self else { return }
                var l=self.limiters[k] ?? WriteLimiter(); l.didWrite(at:Date()); self.limiters[k]=l
                self.drain(k)
            }
        }
    }

    /// Brightness keys: the display under the mouse. Volume keys: the system output. Returns true when the key was consumed.
    func handle(_ key: MediaKey,fine: Bool) -> Bool {
        if key.isBrightness {
            guard brightnessKeys,let d=displayUnderMouse else { return false }
            setBrightness(d.id,BrightnessStep.next(d.brightness,up:key == .brightnessUp,fine:fine),hud:true)
            return true
        }
        // Volume keys: always the Mac's system output, wherever the mouse is (never a monitor's DDC volume).
        return handleSystemVolume(key,fine:fine)
    }
}

/// Intercepts brightness (and volume) media keys with a CGEventTap (needs Accessibility, which the app already has).
/// Installed only while takeover is enabled and no conflicting app runs; re-enabled if the system disables it.
final class MediaKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var handler: ((MediaKey,Bool) -> Bool)?
    var wantsVolume=false
    var isInstalled: Bool { tap != nil }
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask=CGEventMask(1<<14) | CGEventMask(1<<CGEventType.keyDown.rawValue) | CGEventMask(1<<CGEventType.keyUp.rawValue)
        let me=Unmanaged.passUnretained(self).toOpaque()
        guard let t=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{ _,type,event,user in
            guard let user else { return Unmanaged.passUnretained(event) }
            let me=Unmanaged<MediaKeyTap>.fromOpaque(user).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t=me.tap { CGEvent.tapEnable(tap:t,enable:true) }; return Unmanaged.passUnretained(event) }
            return me.process(type,event) ? nil : Unmanaged.passUnretained(event)
        },userInfo:me) else { return false }
        tap=t
        source=CFMachPortCreateRunLoopSource(nil,t,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:t,enable:true)
        return true
    }
    func uninstall() {
        if let t=tap { CGEvent.tapEnable(tap:t,enable:false); CFMachPortInvalidate(t) }
        if let s=source { CFRunLoopRemoveSource(CFRunLoopGetMain(),s,.commonModes) }
        tap=nil; source=nil
    }
    /// Keys whose key-down we consumed; their key-up is consumed too, so the system never sees half a press.
    private var consumed=Set<String>()
    /// Runs on the main run loop.
    private func process(_ type: CGEventType,_ event: CGEvent) -> Bool {
        let fine=event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
        let key: MediaKey,down: Bool
        if type == .keyDown || type == .keyUp {
            guard let k=MediaKey.fromKeyCode(Int(event.getIntegerValueField(.keyboardEventKeycode))) else { return false }
            key=k; down=(type == .keyDown)
        } else {
            guard type.rawValue==14,let ns=NSEvent(cgEvent:event),ns.subtype.rawValue==8,let d=MediaKey.decode(data1:ns.data1) else { return false }
            key=d.key; down=d.down
        }
        if !key.isBrightness && !wantsVolume { return false }
        let id="\(key)"
        if down {
            let handled=handler?(key,fine) ?? false
            if handled { consumed.insert(id) }
            return handled
        }
        return consumed.remove(id) != nil
    }
}

/// Top-centre HUD (just below the menu bar / notch) on the display that changed. Glassy: NSVisualEffectView with
/// behind-window blur, low tint, hairline border and soft shadow. Non-activating, click-through, on every Space.
final class BrightnessHUDCenter {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    static let radius: CGFloat=22
    func show(_ d: ControlledDisplay,kind: BrightnessHUD.Kind) {
        show(name:d.name,percent:d.brightness,kind:kind,note:d.method == .software && kind == .brightness ? lk("软件调暗") : nil,screenID:d.id)
    }
    func show(name: String,percent: Double,kind: BrightnessHUD.Kind,note: String?,screenID: CGDirectDisplayID?) {
        let view=BrightnessHUD(name:name,percent:percent,kind:kind,note:note,liveGlass:true)
        let p=panel ?? {
            let p=NSPanel(contentRect:.zero,styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
            p.isFloatingPanel=true; p.level = .statusBar; p.hidesOnDeactivate=false; p.isReleasedWhenClosed=false
            p.backgroundColor = .clear; p.isOpaque=false; p.hasShadow=true; p.ignoresMouseEvents=true
            p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
            panel=p; return p
        }()
        let hosting=NSHostingView(rootView:view)
        let size=hosting.fittingSize
        let glass=NSVisualEffectView(frame:NSRect(origin:.zero,size:size))
        glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer=true; glass.layer?.cornerRadius=Self.radius; glass.layer?.cornerCurve = .continuous; glass.layer?.masksToBounds=true
        glass.alphaValue=0.55
        let container=NSView(frame:glass.frame)
        container.addSubview(glass)
        hosting.frame=glass.frame; container.addSubview(hosting)
        p.contentView=container
        let screen=NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==screenID } ?? NSScreen.main
        if let f=screen?.visibleFrame { p.setFrame(NSRect(x:f.midX-size.width/2,y:f.maxY-size.height-12,width:size.width,height:size.height),display:true) }
        p.invalidateShadow()
        p.alphaValue=1; p.orderFrontRegardless()
        hide?.cancel()
        let work=DispatchWorkItem { [weak p] in NSAnimationContext.runAnimationGroup({ $0.duration=0.3; p?.animator().alphaValue=0 },completionHandler:{ p?.orderOut(nil) }) }
        hide=work; DispatchQueue.main.asyncAfter(deadline:.now()+1.5,execute:work)
    }
}

/// Wires settings, conflicts and the key tap together. Re-evaluates when apps launch or quit, so takeover starts
/// automatically after BetterDisplay / MonitorControl quits (no restart).
final class DisplayControlCoordinator {
    let control: DisplayControl
    let tap=MediaKeyTap()
    let hud=BrightnessHUDCenter()
    private var observers: [NSObjectProtocol]=[]
    private var distributedObservers: [NSObjectProtocol]=[]
    private var syncTimer: Timer?
    private var isSleepingOrLocked=false
    init(control: DisplayControl) { self.control=control }
    func start(trusted: @escaping () -> Bool) {
        control.showHUD={ [weak self] d,k in self?.hud.show(d,kind:k) }
        control.showVolumeHUD={ [weak self] name,level,muted,screen in self?.hud.show(name:name,percent:level,kind:muted ? .muted : .volume,note:nil,screenID:screen) }
        tap.handler={ [weak self] key,fine in self?.control.handle(key,fine:fine) ?? false }
        control.onKeySettingsChanged={ [weak self] in self?.evaluate(trusted:trusted()) }
        control.onSyncSettingsChanged={ [weak self] in self?.updateSyncTimer() }
        let nc=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.evaluate(trusted:trusted()) })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            self?.control.resetSyncBaseline()
            DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { self?.control.refresh() }
        })
        observers.append(nc.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            self.isSleepingOrLocked=true
            self.control.resetSyncBaseline()
            self.updateSyncTimer()
        })
        observers.append(nc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            self.isSleepingOrLocked=false
            self.control.resetSyncBaseline()
            self.updateSyncTimer()
            DispatchQueue.main.asyncAfter(deadline:.now()+3) { self.control.refresh() }
        })
        let dnc=DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName:Notification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            self.isSleepingOrLocked=true
            self.control.resetSyncBaseline()
            self.updateSyncTimer()
        })
        distributedObservers.append(dnc.addObserver(forName:Notification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            self.isSleepingOrLocked=false
            self.control.resetSyncBaseline()
            self.updateSyncTimer()
        })
        control.refresh()
        evaluate(trusted:trusted())
        updateSyncTimer()
    }
    private func updateSyncTimer() {
        let shouldRun=control.syncWithBuiltIn && !isSleepingOrLocked
        if shouldRun {
            guard syncTimer == nil else { return }
            let timer=Timer(timeInterval:2.0,repeats:true) { [weak self] _ in
                self?.control.pollBuiltInBrightnessForSync()
            }
            syncTimer=timer
            RunLoop.main.add(timer,forMode:.common)
            control.pollBuiltInBrightnessForSync()
        } else {
            syncTimer?.invalidate()
            syncTimer=nil
        }
    }
    /// Called at launch, on app launch/quit, on settings change and when Accessibility changes.
    func evaluate(trusted: Bool) {
        let running=NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let conflicts=KeyTakeover.conflicts(running:running)
        if control.conflicts != conflicts { control.conflicts=conflicts }
        let want=KeyTakeover.active(enabled:control.brightnessKeys || control.volumeKeys,running:running) && trusted
        tap.wantsVolume=control.volumeKeys
        if want && !tap.isInstalled {
            let err: String?=tap.install() ? nil : lk("无法监听亮度键（需要辅助功能权限）")
            if control.keyTapError != err { control.keyTapError=err }
        } else if !want && tap.isInstalled { tap.uninstall() }
        if control.keyTapActive != tap.isInstalled { control.keyTapActive=tap.isInstalled }
    }
    func stop() {
        syncTimer?.invalidate(); syncTimer=nil
        tap.uninstall(); SoftwareDimming.restoreAll()
    }
}

// MARK: - Menu and settings UI

/// Menu-bar section: one block per display, sliders apply live.
struct DisplayMenuSection: View {
    @ObservedObject var control: DisplayControl
    var hasBuiltInAndExternal: Bool {
        control.displays.contains{ $0.method == .builtIn } && control.displays.contains{ $0.method != .builtIn }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Text(lk("显示器")).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,14).padding(.top,4).padding(.bottom,2)
            if control.displays.isEmpty {
                Text(lk("正在读取显示器…")).font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,14).padding(.vertical,6)
            }
            ForEach(Array(control.displays.enumerated()),id:\.element.id) { i,d in
                VStack(alignment:.leading,spacing:6) {
                    HStack(spacing:6) {
                        Image(systemName:d.method == .builtIn ? "laptopcomputer" : "display").foregroundStyle(.secondary)
                        Text(d.name).font(.system(size:13,weight:.semibold)).lineLimit(1)
                        Pill(text:d.badge.0,tone:d.badge.1)
                        Spacer()
                    }
                    row("sun.min","sun.max",Binding(get:{ d.brightness },set:{ control.setBrightness(d.id,$0) }))
                }.padding(.horizontal,14).padding(.vertical,6)
                if i<control.displays.count-1 { Divider().padding(.horizontal,14) }
            }
            if hasBuiltInAndExternal {
                Divider().padding(.horizontal,14)
                HStack(spacing:6) {
                    Toggle(lk("外接屏亮度跟随内建屏幕自动变化"),isOn:$control.syncWithBuiltIn)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size:12))
                    Spacer(minLength:0)
                }.padding(.horizontal,14).padding(.vertical,6)
            }
        }.frame(width:320).padding(.vertical,2)
    }
    func row(_ lo: String,_ hi: String,_ value: Binding<Double>) -> some View {
        HStack(spacing:8) {
            Image(systemName:lo).font(.system(size:11)).foregroundStyle(.secondary).frame(width:16)
            Slider(value:value,in:0...1).controlSize(.small)
            Image(systemName:hi).font(.system(size:13)).foregroundStyle(.secondary).frame(width:18)
            Text("\(Int((value.wrappedValue*100).rounded()))%").font(.system(size:11).monospacedDigit()).foregroundStyle(.secondary).frame(width:34,alignment:.trailing)
        }
    }
}

struct DisplaySettings: View {
    @ObservedObject var control: DisplayControl
    @ObservedObject var model: Model
    var body: some View {
        Form {
            ArrangementSettingsSection(model:model)
            Section(lk("菜单栏")) {
                Toggle(lk("在菜单中显示亮度滑块"),isOn:$control.showInMenu)
            }
            Section(lk("键盘")) {
                Toggle(lk("亮度键调节鼠标所在的屏幕"),isOn:$control.brightnessKeys)
                Toggle(lk("音量键按 3% 一档调节 Mac 的系统音量（关闭则交给 macOS）"),isOn:$control.volumeKeys)
                Text(lk("不管鼠标在哪块屏上，音量键都调当前的声音输出设备，不会去调外接显示器自己的音量。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if !control.conflicts.isEmpty {
                    Label(lk("%@ 正在运行，暂不接管按键，避免一次按键调两次。退出它后会自动接管，不用重启。", "\(control.conflicts.joined(separator:lk("、")))"),systemImage:"exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Tone.warning.color).fixedSize(horizontal:false,vertical:true)
                } else if let e=control.keyTapError {
                    Label(e,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(Tone.warning.color)
                } else {
                    Text(control.keyTapActive ? lk("已接管：亮度键调节鼠标所在的屏幕，音量键按 3% 一档调节系统音量，并显示提示。⌥⇧ + 按键可微调。") : lk("未接管按键。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(lk("外接显示器")) {
                Toggle(lk("外接屏亮度跟随内建屏幕自动变化"),isOn:$control.syncWithBuiltIn)
                Text(lk("内建屏幕随环境光变亮或变暗时，外接显示器按相同幅度自动增减亮度。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Toggle(lk("DDC 不可用时使用软件调暗"),isOn:$control.softwareFallback)
                ForEach(control.displays.filter{ $0.method != .builtIn }) { d in
                    let key=DisplayControl.key(d.id)
                    HStack {
                        Text(d.name); Pill(text:d.badge.0,tone:d.badge.1)
                        Spacer()
                        Toggle(lk("使用 DDC"),isOn:Binding(get:{ !control.ddcDisabled.contains(key) },set:{ on in
                            if on { control.ddcDisabled.remove(key) } else { control.ddcDisabled.insert(key) }
                        })).toggleStyle(.switch).controlSize(.small)
                    }
                }
                HStack { Text(lk("显示器不响应或数值不对时，可以关掉它的 DDC 改用软件调暗。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(lk("重新检测")) { control.refresh() }.controlSize(.small) }
            }
        }.formStyle(.grouped)
    }
}
