// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import CoreAudio
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
    /// 0.6.15: the DDC channel is known to belong to this display (resolved through its framebuffer, or the only
    /// external display). Input switching and speaker volume need it; brightness doesn't.
    var mappingCertain=false
    var badge: (String,Tone) {
        switch method { case .builtIn: return (lk("内建"),.neutral); case .ddc: return ("DDC",.success); case .software: return (lk("软件调暗"),.warning) }
    }
    static func == (a: ControlledDisplay,b: ControlledDisplay) -> Bool {
        a.id==b.id && a.name==b.name && a.method==b.method && a.brightness==b.brightness && a.mappingCertain==b.mappingCertain
    }
}

/// Brightness for every display: DDC for external monitors (software dimming when DDC fails), DisplayServices for the
/// built-in screen. DDC I/O runs on a serial queue; writes are rate limited and coalesced (latest value wins).
/// The volume keys change the current sound output (`SystemVolume`). 0.6.15: when that output is a monitor's HDMI/DP
/// audio macOS can't set, they change that monitor's speakers over DDC (VCP 0x62 / 0x8D) instead.
/// 0.6.15: 「切换输入源」 writes VCP 0x60 (or the LG alternate) once, only on a click the user confirmed.
final class DisplayControl: ObservableObject {
    @Published private(set) var displays: [ControlledDisplay]=[]
    @Published var showInMenu: Bool { didSet { defaults?.set(showInMenu,forKey:DisplayControlPrefs.showInMenu) } }
    @Published var brightnessKeys: Bool { didSet { defaults?.set(brightnessKeys,forKey:DisplayControlPrefs.brightnessKeys); onKeySettingsChanged?() } }
    @Published var volumeKeys: Bool { didSet { defaults?.set(volumeKeys,forKey:DisplayControlPrefs.volumeKeys); onKeySettingsChanged?(); refreshSpeakers() } }
    @Published var monitorSpeakerKeys: Bool { didSet { defaults?.set(monitorSpeakerKeys,forKey:DisplayControlPrefs.monitorSpeakerKeys); refreshSpeakers() } }
    @Published var inputMenu: Bool { didSet { defaults?.set(inputMenu,forKey:DisplayControlPrefs.inputMenu) } }
    @Published private(set) var inputSourceMap: [String:[InputSource]]
    @Published var inputConfirmed: Set<String> { didSet { defaults?.set(Array(inputConfirmed),forKey:DisplayControlPrefs.inputConfirmed) } }
    @Published var audioOverrides: [String:String] { didSet { defaults?.set(audioOverrides,forKey:DisplayControlPrefs.audioDeviceOverrides); refreshSpeakers() } }
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
    /// Volume HUD: output device name, level, muted, the screen to show it on, and an optional note ("显示器喇叭").
    var showVolumeHUD: ((String,Double,Bool,CGDirectDisplayID?,String?) -> Void)?

    private let defaults: UserDefaults?
    private let io=DispatchQueue(label:"layoutkeeper.ddc")
    private var services: [CGDirectDisplayID:DDCService]=[:]
    private var limiters: [String:WriteLimiter]=[:]
    private var pending: [String:(DDCService,UInt8,UInt16)]=[:]
    private var draining: Set<String>=[]
    private var refreshing=false
    private var lastSyncedBuiltIn: Double?
    /// Monitor speaker state per display, from DDC reads and our own writes.
    struct SpeakerInfo { var state: SpeakerLevel; var max: Int; var hardwareMute: Bool; var readOK: Bool }
    private var speakers: [CGDirectDisplayID:SpeakerInfo]=[:]
    private var lastSpeakerKey: [CGDirectDisplayID:Date]=[:]
    private var readingSpeakers=false
    /// Displays whose speaker volume couldn't be read; not retried until the output changes or a setting is touched.
    private var speakerReadFailed=Set<CGDirectDisplayID>()

    init(defaults: UserDefaults?=Prefs.store) {
        self.defaults=defaults
        func b(_ k: String,_ d: Bool) -> Bool { defaults?.object(forKey:k) == nil ? d : (defaults?.bool(forKey:k) ?? d) }
        showInMenu=b(DisplayControlPrefs.showInMenu,true)
        brightnessKeys=b(DisplayControlPrefs.brightnessKeys,true)
        volumeKeys=b(DisplayControlPrefs.volumeKeys,true)
        softwareFallback=b(DisplayControlPrefs.softwareFallback,true)
        ddcDisabled=Set(defaults?.stringArray(forKey:DisplayControlPrefs.ddcDisabled) ?? [])
        syncWithBuiltIn=b(DisplayControlPrefs.syncWithBuiltIn,false)
        monitorSpeakerKeys=b(DisplayControlPrefs.monitorSpeakerKeys,true)
        inputMenu=b(DisplayControlPrefs.inputMenu,true)
        inputSourceMap=InputSourceStore.decode(defaults?.data(forKey:DisplayControlPrefs.inputSources))
        inputConfirmed=Set(defaults?.stringArray(forKey:DisplayControlPrefs.inputConfirmed) ?? [])
        audioOverrides=(defaults?.dictionary(forKey:DisplayControlPrefs.audioDeviceOverrides) as? [String:String]) ?? [:]
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
            let (map0,certain)=Self.serviceMap(externals)
            var map=map0
            var out=[ControlledDisplay]()
            for id in ids {
                let name=Self.name(id)
                if CGDisplayIsBuiltin(id) != 0 {
                    if let b=BuiltInBrightness.get(id) { out.append(ControlledDisplay(id:id,name:name,method:.builtIn,brightness:b)) }
                    continue
                }
                if !disabled.contains(Self.key(id)),let s=map[id],let b=s.readVCP(DDCPacket.brightness) {
                    out.append(ControlledDisplay(id:id,name:name,method:.ddc,brightness:BrightnessStep.fromDDC(b.current,max:b.max),ddcMax:b.max,mappingCertain:certain.contains(id)))
                } else if fallback {
                    map[id]=nil
                    out.append(ControlledDisplay(id:id,name:name,method:.software,brightness:previous.first{ $0.id==id && $0.method == .software }?.brightness ?? 1))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.services=map; self.displays=out; self.refreshing=false
                let present=Set(out.map(\.id))
                self.speakers=self.speakers.filter{ present.contains($0.key) }
                self.speakerReadFailed=self.speakerReadFailed.filter{ present.contains($0) }
                self.lastSpeakerKey=self.lastSpeakerKey.filter{ present.contains($0.key) }
                if self.syncWithBuiltIn,!SystemSleepGuard.clamshellState(),let b=out.first(where:{ $0.method == .builtIn })?.brightness {
                    if self.lastSyncedBuiltIn == nil { self.lastSyncedBuiltIn=b }
                } else {
                    self.lastSyncedBuiltIn=nil
                }
                if !fallback { SoftwareDimming.restoreAll() }
                self.refreshSpeakers(all:false)
            }
        }
    }

    /// Which AV service drives which external display. Resolved through each display's framebuffer when every external
    /// display can be resolved that way (all certain). Otherwise the pre-0.6.15 registry-order pairing is kept for
    /// brightness (only when the counts agree), and only a single external display counts as certain. If that pairing
    /// isn't possible, the displays that were resolved individually are used.
    static func serviceMap(_ externals: [CGDirectDisplayID]) -> ([CGDirectDisplayID:DDCService],Set<CGDirectDisplayID>) {
        guard !externals.isEmpty else { return ([:],[]) }
        let precise=DDCService.servicesByDisplay(externals)
        if externals.allSatisfy({ precise[$0] != nil }) { return (precise,Set(externals)) }
        let svcs=DDCService.externalServices()
        if svcs.count==externals.count {
            var map=[CGDirectDisplayID:DDCService]()
            for (i,id) in externals.enumerated() { map[id]=svcs[i] }
            return (map,externals.count==1 ? Set(externals) : [])
        }
        return (precise,Set(precise.keys))
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
            showVolumeHUD?(name,SystemVolume.volume(output.device) ?? 0,muted,screen,nil)
            return true
        }
        guard let current=SystemVolume.volume(output.device) else { return false }
        let next=BrightnessStep.next(current,up:key == .volumeUp,fine:fine,coarse:BrightnessStep.volumeCoarse)
        guard SystemVolume.setVolume(output.device,next) else { return false }
        // Like macOS: changing the level unmutes (and volume down to 0 leaves it at 0, not muted).
        if output.muteSettable,SystemVolume.muted(output.device) == true { SystemVolume.setMuted(output.device,false) }
        showVolumeHUD?(name,SystemVolume.volume(output.device) ?? next,false,screen,nil)
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

    /// Brightness keys: the display under the mouse. Volume keys: the current sound output, wherever the mouse is; a
    /// monitor's speakers only when that monitor is the output and macOS can't set its volume. Returns true when the key
    /// was consumed.
    func handle(_ key: MediaKey,fine: Bool) -> Bool {
        if key.isBrightness {
            guard brightnessKeys,let d=displayUnderMouse else { return false }
            setBrightness(d.id,BrightnessStep.next(d.brightness,up:key == .brightnessUp,fine:fine),hud:true)
            return true
        }
        guard volumeKeys else { return false }
        let output=SystemVolume.defaultOutput()
        let target=output.flatMap{ speakerTarget($0) }
        switch VolumeKeyRouting.route(key,enabled:volumeKeys,outputVolumeSettable:output?.volumeSettable == true,outputMuteSettable:output?.muteSettable == true,
                                      monitorSpeakerEnabled:monitorSpeakerKeys,speakerDisplay:target) {
        case .monitorSpeaker(let id): return handleMonitorSpeaker(id,key,fine:fine)
        case .systemOutput: return handleSystemVolume(key,fine:fine)
        case .passThrough:
            // A monitor output not matched yet (speaker volume not read): read now so the next press can use it.
            if let output,monitorSpeakerKeys,!output.volumeSettable,MonitorAudioMatcher.isDisplayTransport(output.transport) { refreshSpeakers(all:false) }
            return false
        }
    }

    // MARK: Monitor speakers (0.6.15)

    /// The monitor whose speakers play `output`, or nil (see `MonitorAudioMatcher`).
    func speakerTarget(_ output: SystemVolume.Output) -> CGDirectDisplayID? {
        guard monitorSpeakerKeys,!output.volumeSettable,MonitorAudioMatcher.isDisplayTransport(output.transport) else { return nil }
        let candidates=displays.filter{ $0.method == .ddc && $0.mappingCertain && services[$0.id] != nil }.map { d in
            MonitorAudioMatcher.Candidate(id:d.id,name:d.name,hasSpeakerVolume:speakers[d.id]?.readOK == true,overrideDevice:audioOverrides[Self.key(d.id)])
        }
        let externalCount=Self.onlineDisplays().filter{ CGDisplayIsBuiltin($0)==0 }.count
        return MonitorAudioMatcher.match(deviceName:output.name,transport:output.transport,volumeSettable:output.volumeSettable,candidates:candidates,externalCount:externalCount)
    }
    private func handleMonitorSpeaker(_ id: CGDirectDisplayID,_ key: MediaKey,fine: Bool) -> Bool {
        guard let d=displays.first(where:{ $0.id==id }),let s=services[id] else { return false }
        var info=speakers[id] ?? SpeakerInfo(state:SpeakerLevel(level:SpeakerLevel.unknownStart),max:100,hardwareMute:false,readOK:false)
        let (next,writes)=info.state.press(key,fine:fine,hardwareMute:info.hardwareMute)
        info.state=next; speakers[id]=info; lastSpeakerKey[id]=Date()
        for w in writes {
            switch w {
            case .volume(let v): enqueue(s,id,DDCPacket.speakerVolume,BrightnessStep.toDDC(v,max:info.max))
            case .mute(let m): enqueue(s,id,DDCPacket.audioMute,m ? 1 : 2)
            }
        }
        showVolumeHUD?(d.name,next.level,next.muted,id,lk("显示器喇叭"))
        return true
    }
    /// Reads speaker volume (0x62) and mute (0x8D) off the main thread, only while the sound output is a monitor whose
    /// volume macOS can't set. A failed read keeps what was known; a read that started before a key press is dropped.
    /// `all`: re-read every monitor (output changed, setting touched). Otherwise (display refresh, menu open) only
    /// monitors not read yet, so opening the menu doesn't keep the DDC queue busy.
    func refreshSpeakers(all: Bool=true) {
        guard !RenderMode.snapshot,volumeKeys,monitorSpeakerKeys,!readingSpeakers else { return }
        if all { speakerReadFailed.removeAll() }
        guard let out=SystemVolume.defaultOutput(),!out.volumeSettable,MonitorAudioMatcher.isDisplayTransport(out.transport) else { return }
        let targets=displays.filter{ d in
            d.method == .ddc && d.mappingCertain && !speakerReadFailed.contains(d.id) && (all || speakers[d.id]?.readOK != true)
        }.compactMap{ d in services[d.id].map{ (d.id,$0) } }
        guard !targets.isEmpty else { return }
        readingSpeakers=true
        let started=Date()
        io.async { [weak self] in
            var reads: [(CGDirectDisplayID,(current: Int,max: Int)?,(current: Int,max: Int)?)]=[]
            for (id,s) in targets {
                let v=s.readVCP(DDCPacket.speakerVolume)
                reads.append((id,v,v == nil ? nil : s.readVCP(DDCPacket.audioMute)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingSpeakers=false
                for (id,v,m) in reads {
                    guard let v else { self.speakerReadFailed.insert(id); continue }
                    if let last=self.lastSpeakerKey[id],last >= started { continue }
                    let hardwareMute=m.map{ $0.current == 1 || $0.current == 2 } ?? false
                    let state=SpeakerLevel.merged(existing:self.speakers[id]?.state,readLevel:BrightnessStep.fromDDC(v.current,max:v.max),
                                                  readMuted:m.map{ $0.current == 1 },hardwareMute:hardwareMute)
                    self.speakers[id]=SpeakerInfo(state:state,max:v.max,hardwareMute:hardwareMute,readOK:true)
                }
            }
        }
    }

    // MARK: Input source (0.6.15)

    func inputSources(for id: CGDirectDisplayID) -> [InputSource] { InputSourceStore.sources(inputSourceMap,key:Self.key(id)) }
    func setInputSources(_ list: [InputSource],for id: CGDirectDisplayID) {
        inputSourceMap=InputSourceStore.setting(inputSourceMap,key:Self.key(id),sources:list)
        defaults?.set(InputSourceStore.encode(inputSourceMap),forKey:DisplayControlPrefs.inputSources)
    }
    /// The 「切换输入源」 submenu, or nil when it is off or no monitor has DDC.
    func inputMenuModel() -> InputMenu? {
        guard inputMenu else { return nil }
        let list=displays.filter{ $0.method == .ddc }.map { d in
            InputMenu.Display(id:d.id,name:d.name,blocked:d.mappingCertain ? nil : lk("无法确认这台显示器对应的 DDC 通道"),sources:inputSources(for:d.id))
        }
        return list.isEmpty ? nil : InputMenu(displays:list)
    }
    func inputDecision(_ id: CGDirectDisplayID) -> InputSwitchDecision {
        guard let d=displays.first(where:{ $0.id==id }) else { return .blocked(lk("这台显示器没有可用的 DDC")) }
        return InputSwitchPolicy.decide(isBuiltIn:d.method == .builtIn,ddcAvailable:d.method == .ddc && services[id] != nil,mappingCertain:d.mappingCertain,
                                        isOnlyActiveScreen:Self.onlineDisplays() == [id],confirmedBefore:inputConfirmed.contains(Self.key(id)))
    }
    /// One write of the input command (the I2C layer retries once only when the write itself fails). `done(false)`: the
    /// write didn't go through. A monitor that takes the write and ignores it can't be detected.
    func switchInput(_ id: CGDirectDisplayID,to source: InputSource,done: @escaping (Bool) -> Void) {
        guard let d=displays.first(where:{ $0.id==id }),d.method == .ddc,d.mappingCertain,let s=services[id] else { done(false); return }
        let cmd=source.command
        io.async {
            let ok=s.writeVCP(cmd.code,UInt16(source.value),subAddress:cmd.subAddress)
            DispatchQueue.main.async { done(ok) }
        }
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
    private var audioListener: AudioObjectPropertyListenerBlock?
    init(control: DisplayControl) { self.control=control }
    func start(trusted: @escaping () -> Bool) {
        control.showHUD={ [weak self] d,k in self?.hud.show(d,kind:k) }
        control.showVolumeHUD={ [weak self] name,level,muted,screen,note in self?.hud.show(name:name,percent:level,kind:muted ? .muted : .volume,note:note,screenID:screen) }
        audioListener=SystemVolume.observeDefaultOutput { [weak self] in self?.control.refreshSpeakers() }
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
        if let l=audioListener { SystemVolume.stopObserving(l); audioListener=nil }
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
    @State var editing: ControlledDisplay?
    @State var audioDevices: [String]=[]
    /// HDMI/DP output devices present now, plus the one chosen before (it may be unplugged).
    private func deviceChoices(_ key: String) -> [String] {
        var list=audioDevices
        if let chosen=control.audioOverrides[key],!list.contains(chosen) { list.append(chosen) }
        return list.sorted()
    }
    var body: some View {
        Form {
            ArrangementSettingsSection(model:model)
            Section(lk("菜单栏")) {
                Toggle(lk("在菜单中显示亮度滑块"),isOn:$control.showInMenu)
                Toggle(lk("在菜单中显示「切换输入源」"),isOn:$control.inputMenu)
            }
            Section(lk("键盘")) {
                Toggle(lk("亮度键调节鼠标所在的屏幕"),isOn:$control.brightnessKeys)
                Toggle(lk("音量键按 3% 一档调节 Mac 的系统音量（关闭则交给 macOS）"),isOn:$control.volumeKeys)
                Text(lk("音量键调当前的声音输出设备，和鼠标在哪块屏上无关。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Toggle(lk("声音从显示器输出时，音量键调显示器喇叭"),isOn:$control.monitorSpeakerKeys).disabled(!control.volumeKeys)
                Text(lk("只在 macOS 调不了这台显示器的音量时生效，显示器需要支持 DDC 音量。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if !control.conflicts.isEmpty {
                    Label(lk("%@ 正在运行，暂不接管按键，避免一次按键调两次。退出它后会自动接管，不用重启。", "\(control.conflicts.joined(separator:lk("、")))"),systemImage:"exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Tone.warning.color).fixedSize(horizontal:false,vertical:true)
                } else if let e=control.keyTapError {
                    Label(e,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(Tone.warning.color)
                } else {
                    Text(control.keyTapActive ? lk("已接管：亮度键调节鼠标所在的屏幕，音量键按 3% 一档调节当前声音输出，并显示提示。⌥⇧ + 按键可微调。") : lk("未接管按键。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(lk("外接显示器")) {
                Toggle(lk("外接屏亮度跟随内建屏幕自动变化"),isOn:$control.syncWithBuiltIn)
                Text(lk("内建屏幕随环境光变亮或变暗时，外接显示器按相同幅度自动增减亮度。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Toggle(lk("DDC 不可用时使用软件调暗"),isOn:$control.softwareFallback)
                ForEach(control.displays.filter{ $0.method != .builtIn }) { d in
                    let key=DisplayControl.key(d.id)
                    VStack(alignment:.leading,spacing:6) {
                        HStack {
                            Text(d.name); Pill(text:d.badge.0,tone:d.badge.1)
                            Spacer()
                            if d.method == .ddc { Button(lk("输入源…")) { editing=d }.controlSize(.small) }
                            Toggle(lk("使用 DDC"),isOn:Binding(get:{ !control.ddcDisabled.contains(key) },set:{ on in
                                if on { control.ddcDisabled.remove(key) } else { control.ddcDisabled.insert(key) }
                            })).toggleStyle(.switch).controlSize(.small)
                        }
                        if d.method == .ddc,control.volumeKeys,control.monitorSpeakerKeys,!(audioDevices.isEmpty && control.audioOverrides[key] == nil) {
                            Picker(lk("声音设备"),selection:Binding(get:{ control.audioOverrides[key] ?? "" },set:{ v in
                                if v.isEmpty { control.audioOverrides[key]=nil } else { control.audioOverrides[key]=v }
                            })) {
                                Text(lk("自动")).tag("")
                                ForEach(deviceChoices(key),id:\.self) { Text($0).tag($0) }
                            }.controlSize(.small)
                        }
                    }
                }
                HStack { Text(lk("显示器不响应或数值不对时，可以关掉它的 DDC 改用软件调暗。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(lk("重新检测")) { control.refresh(); audioDevices=SystemVolume.displayOutputNames() }.controlSize(.small) }
                #if !arch(arm64)
                Text(lk("输入源切换和显示器喇叭音量只支持 Apple 芯片的 Mac。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                #endif
            }
        }.formStyle(.grouped)
        .onAppear { if !RenderMode.snapshot { audioDevices=SystemVolume.displayOutputNames() } }
        .sheet(item:$editing) { d in InputSourceEditor(control:control,display:d) { editing=nil } }
    }
}

/// 0.6.15: edit one monitor's 「切换输入源」 list. Changes are saved on 「完成」.
struct InputSourceEditor: View {
    @ObservedObject var control: DisplayControl
    let display: ControlledDisplay
    let close: () -> Void
    struct Row: Identifiable, Equatable { var source: InputSource; var valueText: String; var id: String { source.id } }
    @State var rows: [Row]=[]
    private func load(_ list: [InputSource]) { rows=list.map{ Row(source:$0,valueText:InputValueParser.format($0.value)) } }
    private func valid(_ r: Row) -> Bool {
        InputValueParser.parse(r.valueText) != nil && !r.source.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    private var allValid: Bool { rows.allSatisfy(valid) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(lk("%@ 的输入源", display.name)).font(.headline)
            Grid(alignment:.leading,horizontalSpacing:10,verticalSpacing:6) {
                GridRow {
                    Text(lk("在菜单中显示")); Text(lk("名称")); Text(lk("数值")); Text(lk("LG 备用指令")); Text("")
                }.font(.caption).foregroundStyle(.secondary)
                ForEach($rows) { $r in
                    GridRow {
                        Toggle("",isOn:$r.source.visible).labelsHidden().toggleStyle(.checkbox)
                        TextField("",text:$r.source.name).frame(width:150)
                        TextField("",text:$r.valueText).frame(width:70)
                            .foregroundStyle(InputValueParser.parse(r.valueText) == nil ? Tone.warning.color : Color.primary)
                        Toggle("",isOn:$r.source.lgAlt).labelsHidden().toggleStyle(.checkbox)
                        Button { let id=r.id; DispatchQueue.main.async { rows.removeAll{ $0.id == id } } } label:{ Image(systemName:"minus.circle") }.buttonStyle(.borderless).help(lk("删除"))
                    }
                }
            }
            Text(lk("数值以显示器说明书为准，可填十进制或 0x 开头的十六进制。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(lk("很多显示器报告的当前输入不准，菜单里不标当前输入。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button(lk("添加")) {
                    let id=InputMenu.sanitizedSourceID("c"+UUID().uuidString.prefix(8).lowercased())
                    rows.append(Row(source:InputSource(id:id,name:lk("自定义输入源"),value:0x11),valueText:"0x11"))
                }
                Button(lk("恢复默认")) { load(InputSourceCatalog.defaults) }
                Spacer()
                Button(lk("取消")) { close() }.keyboardShortcut(.cancelAction)
                Button(lk("完成")) {
                    let list=rows.compactMap { r -> InputSource? in
                        guard let v=InputValueParser.parse(r.valueText) else { return nil }
                        var s=r.source; s.value=v; s.name=s.name.trimmingCharacters(in:.whitespacesAndNewlines); return s
                    }
                    control.setInputSources(list,for:display.id); close()
                }.keyboardShortcut(.defaultAction).disabled(!allValid)
            }
        }
        .padding(20).frame(minWidth:460)
        .onAppear { load(control.inputSources(for:display.id)) }
    }
}
