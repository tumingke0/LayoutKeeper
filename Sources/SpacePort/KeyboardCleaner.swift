// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import Carbon
import IOKit
import SwiftUI
import LayoutCore

/// 「清理键盘」: a session event tap drops keyboard events (and optionally clicks / scrolling / gestures) while a
/// dimmed overlay covers every display. Ends on 「完成」, when time is up, after holding Esc for 3 seconds, or when
/// macOS turns the tap off and it can't be turned back on. The tap belongs to this process, so if LayoutKeeper
/// crashes or quits the keyboard works again at once. Uses the existing Accessibility permission only.
final class KeyboardCleaner {
    enum StartResult: Equatable { case started, alreadyLocked, notTrusted, tapFailed }
    private(set) var session: KeyboardCleanSession?
    var isLocked: Bool { session != nil }
    var onStart: () -> Void={}
    var onEnd: (KeyboardCleanEndReason) -> Void={ _ in }
    var log: (String) -> Void={ _ in }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var windows: [NSWindow]=[]
    private var timer: Timer?
    private var observers: [(NotificationCenter,NSObjectProtocol)]=[]
    private var escape=EscapeHold()
    private var capsLockBefore: Bool?
    private var lastFlags: UInt64=0
    private var state: KeyboardCleanViewState?

    func start(settings: KeyboardCleanSettings) -> StartResult {
        guard session == nil else { return .alreadyLocked }
        guard AXIsProcessTrusted() else { return .notTrusted }
        let s=KeyboardCleanSession(start:Date(),settings:settings)
        guard installTap(blockPointer:s.blockPointer) else { return .tapFailed }
        session=s
        capsLockBefore=CapsLock.get()
        lastFlags=CGEventSource.flagsState(.hidSystemState).rawValue
        escape=EscapeHold()
        let st=KeyboardCleanViewState(blockPointer:s.blockPointer,remaining:s.remaining(at:Date()))
        st.secureInput=IsSecureEventInputEnabled()
        st.onDone={ [weak self] in self?.finish(.done) }
        state=st
        onStart()
        NSApp.activate(ignoringOtherApps:true)
        buildOverlays()
        let nc=NotificationCenter.default, wc=NSWorkspace.shared.notificationCenter
        observers.append((nc,nc.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.buildOverlays() }))
        observers.append((wc,wc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            self?.tick(); self?.buildOverlays()
        }))
        let t=Timer(timeInterval:0.1,repeats:true) { [weak self] _ in self?.tick() }
        timer=t; RunLoop.main.add(t,forMode:.common)
        // Second check once the overlay has focus: a secure-input field elsewhere may still hold it.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in
            if let st=self?.state,IsSecureEventInputEnabled() { st.secureInput=true }
        }
        log("keyboard clean: locked duration=\(Int(s.endsAt.timeIntervalSince(s.startedAt)))s blockPointer=\(s.blockPointer) capsLock=\(capsLockBefore.map{"\($0)"} ?? "unknown") secureInput=\(st.secureInput)")
        return .started
    }

    /// Safe to call at any time (does nothing when not locked).
    func finish(_ reason: KeyboardCleanEndReason) {
        guard session != nil else { return }
        session=nil
        uninstallTap()
        timer?.invalidate(); timer=nil
        for (center,o) in observers { center.removeObserver(o) }
        observers=[]
        for w in windows { w.orderOut(nil) }
        windows=[]
        if let before=capsLockBefore,let now=CapsLock.get(),now != before { CapsLock.set(before) }
        capsLockBefore=nil
        let blocked=state?.blocked ?? 0
        state=nil
        log("keyboard clean: unlocked reason=\(reason.rawValue) blocked=\(blocked)")
        onEnd(reason)
    }

    private func tick() {
        guard let session,let state else { return }
        let now=Date()
        if session.isExpired(at:now) { finish(.timeout); return }
        if escape.isComplete(at:now) { finish(.escape); return }
        if let t=tap,!CGEvent.tapIsEnabled(tap:t) {
            CGEvent.tapEnable(tap:t,enable:true)
            if !CGEvent.tapIsEnabled(tap:t) { finish(.tapLost); return }
        }
        let remaining=session.remaining(at:now)
        if Int(remaining.rounded(.up)) != Int(state.remaining.rounded(.up)) { state.remaining=remaining }
        let progress=escape.progress(at:now)
        if abs(progress-state.escapeProgress)>0.001 { state.escapeProgress=progress }
    }

    // MARK: Event tap (written like MediaKeyTap in DisplayControl.swift)

    private func installTap(blockPointer: Bool) -> Bool {
        guard tap == nil else { return true }
        var mask=CGEventMask(0)
        for type in KeyboardCleanFilter.tapTypes(blockPointer:blockPointer) { mask |= CGEventMask(1) << CGEventMask(type) }
        let me=Unmanaged.passUnretained(self).toOpaque()
        guard let t=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:{ _,type,event,user in
            guard let user else { return Unmanaged.passUnretained(event) }
            let me=Unmanaged<KeyboardCleaner>.fromOpaque(user).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t=me.tap {
                    CGEvent.tapEnable(tap:t,enable:true)
                    if !CGEvent.tapIsEnabled(tap:t) { DispatchQueue.main.async { me.finish(.tapLost) } }
                }
                return Unmanaged.passUnretained(event)
            }
            return me.process(type,event) ? nil : Unmanaged.passUnretained(event)
        },userInfo:me) else { return false }
        tap=t
        source=CFMachPortCreateRunLoopSource(nil,t,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:t,enable:true)
        guard CGEvent.tapIsEnabled(tap:t) else { uninstallTap(); return false }
        return true
    }
    private func uninstallTap() {
        if let t=tap { CGEvent.tapEnable(tap:t,enable:false); CFMachPortInvalidate(t) }
        if let s=source { CFRunLoopRemoveSource(CFRunLoopGetMain(),s,.commonModes) }
        tap=nil; source=nil
    }
    /// Runs on the main run loop. true = drop the event.
    private func process(_ type: CGEventType,_ event: CGEvent) -> Bool {
        guard let session else { return false }
        let raw=type.rawValue
        var subtype=0,keyCode=0,autorepeat=false,mediaDown=true
        switch raw {
        case KeyboardCleanFilter.keyDown,KeyboardCleanFilter.keyUp:
            keyCode=Int(event.getIntegerValueField(.keyboardEventKeycode))
            autorepeat=event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        case KeyboardCleanFilter.systemDefined:
            if let ns=NSEvent(cgEvent:event) {
                subtype=Int(ns.subtype.rawValue)
                let s=KeyboardCleanFilter.mediaKeyState(data1:ns.data1)
                mediaDown=s.down; autorepeat=s.repeating
            }
        default: break
        }
        let verdict=KeyboardCleanFilter.verdict(type:raw,subtype:subtype,keyCode:keyCode,autorepeat:autorepeat,mediaKeyDown:mediaDown,blockPointer:session.blockPointer)
        switch verdict {
        case .escapeDown: escape.escapeDown(at:Date())
        case .escapeUp: escape.escapeUp()
        case .dropCounted: escape.otherKey(); state?.blocked+=1
        case .drop:
            if raw == KeyboardCleanFilter.flagsChanged {
                let flags=event.flags.rawValue
                if KeyboardCleanFilter.isModifierPress(old:lastFlags,new:flags) { escape.otherKey(); state?.blocked+=1 }
                lastFlags=flags
            }
        case .pass: break
        }
        return verdict.drops
    }

    // MARK: Overlay

    private func buildOverlays() {
        guard let state else { return }
        for w in windows { w.orderOut(nil) }
        windows=[]
        let main=NSScreen.main
        for screen in NSScreen.screens {
            let w=KeyboardCleanWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
            w.setFrame(screen.frame,display:false)
            w.level = .screenSaver
            w.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
            w.isOpaque=false; w.backgroundColor = .clear; w.hasShadow=false
            w.isReleasedWhenClosed=false; w.hidesOnDeactivate=false
            w.contentView=FirstMouseHostingView(rootView:KeyboardCleanOverlay(state:state))
            windows.append(w)
            if screen == main { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        }
        if let first=windows.first,!windows.contains(where:\.isKeyWindow) { first.makeKeyAndOrderFront(nil) }
    }
}

/// Values shown on the overlay (one shared instance for all displays).
final class KeyboardCleanViewState: ObservableObject {
    let blockPointer: Bool
    @Published var remaining: TimeInterval
    @Published var blocked=0
    @Published var escapeProgress: Double=0
    @Published var secureInput=false
    var onDone: () -> Void={}
    init(blockPointer: Bool,remaining: TimeInterval) { self.blockPointer=blockPointer; self.remaining=remaining }
}

/// Borderless, but able to take key focus (second line of defence: any key that gets past the tap lands here).
private final class KeyboardCleanWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

/// 「完成」 works with the first click, even before the window is key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct KeyboardCleanOverlay: View {
    @ObservedObject var state: KeyboardCleanViewState
    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing:16) {
                Image(systemName:"lock.fill").font(.system(size:52,weight:.semibold))
                Text(lk("键盘已锁住")).font(.system(size:34,weight:.bold))
                Text(state.blockPointer ? lk("可以擦了，键盘和触控板都已锁住。") : lk("可以擦了，触控板和鼠标照常能用。"))
                    .font(.title3).foregroundStyle(.white.opacity(0.85))
                Text(lk("%@ 后自动解锁", KeyboardCleanSession.countdownText(state.remaining)))
                    .font(.system(size:22,weight:.medium).monospacedDigit())
                Text(lk("已挡住 %@ 次按键", "\(state.blocked)"))
                    .font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                // With clicks blocked the button could not be pressed, so it is not shown; Esc and the timer remain.
                if !state.blockPointer {
                    Button { state.onDone() } label: { Text(lk("完成")).frame(minWidth:120) }
                        .buttonStyle(.borderedProminent).controlSize(.large).padding(.top,6)
                }
                VStack(spacing:6) {
                    if state.escapeProgress > 0 {
                        ProgressView(value:state.escapeProgress).progressViewStyle(.linear).tint(.white).frame(width:220)
                        Text(lk("继续按住 Esc…"))
                    } else {
                        Text(state.blockPointer ? lk("按住 Esc 3 秒解锁") : lk("按住 Esc 3 秒也能解锁"))
                    }
                }
                .font(.callout).frame(minHeight:40)
                Text(lk("电源键和 Touch ID 锁不住，擦的时候避开。"))
                    .font(.callout).foregroundStyle(.white.opacity(0.65))
                if state.secureInput {
                    Label(lk("有应用开着安全输入，部分按键可能漏过去。"),systemImage:"exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.yellow)
                }
            }
            .multilineTextAlignment(.center).padding(40)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme,.dark)
    }
}

/// Caps Lock state lives below the event tap, so wiping can toggle it; it is put back when the lock ends.
enum CapsLock {
    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t=0
        // 1 = kIOHIDParamConnectType
        guard IOServiceOpen(service,mach_task_self_,1,&connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }
    /// 1 = kIOHIDCapsLockState
    static func get() -> Bool? {
        withConnection { c -> Bool? in
            var on=false
            return IOHIDGetModifierLockState(c,1,&on) == KERN_SUCCESS ? on : nil
        } ?? CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }
    static func set(_ on: Bool) {
        _=withConnection { c -> Bool? in IOHIDSetModifierLockState(c,1,on) == KERN_SUCCESS }
    }
}
