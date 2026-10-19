// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import LayoutCore

/// Experimental: drives Mission Control (owned by Dock) through public Accessibility APIs to add or remove Spaces.
/// No SIP change, no injection. Every call fails closed: when the expected element is missing it throws and does nothing.
///
/// Expected tree (Dock): AXGroup id="mc" → AXGroup id="mc.display" (one per display, frame = display) →
/// AXGroup id="mc.spaces" → AXButton id="mc.spaces.add" (press = add Space) and AXList id="mc.spaces.list" →
/// AXButton per Space (action "AXRemoveDesktop" = the hover × button).
public final class MissionControlDriver {
    public enum Failure: Error, CustomStringConvertible {
        case notTrusted, dockMissing, didNotOpen, displayNotFound, addButtonMissing, listMissing, removeUnsupported, axError(Int32)
        /// Every try of `MissionControlOpening.attempts` was made and Mission Control never showed its desks.
        case didNotOpenAfter(tried: [MissionControlOpening.Method],ctrlUpEnabled: Bool)
        public var description: String {
            switch self {
            case .notTrusted: return lk("没有辅助功能权限")
            case .dockMissing: return lk("找不到程序坞进程")
            case .didNotOpen: return lk("调度中心没有打开")
            case .displayNotFound: return lk("调度中心里找不到这块屏幕")
            case .addButtonMissing: return lk("调度中心里找不到「+」按钮")
            case .listMissing: return lk("调度中心里找不到桌面列表")
            case .removeUnsupported: return lk("这个系统版本的调度中心不支持关闭桌面")
            case .axError(let e): return lk("辅助功能调用失败（%@）", "\(e)")
            case .didNotOpenAfter(let tried,let ctrlUp): return MissionControlOpening.failureText(tried:tried,ctrlUpEnabled:ctrlUp)
            }
        }
    }
    public init() {}

    /// macOS ≤15: Mission Control lives in the Dock. macOS 27: the live UI is in WindowManager (com.apple.WindowManager);
    /// the Dock still exposes an empty zero-frame mc group. Search both, WindowManager first.
    private var hosts: [AXUIElement] {
        ["com.apple.WindowManager","com.apple.dock"].compactMap { NSRunningApplication.runningApplications(withBundleIdentifier:$0).first.map { AXUIElementCreateApplication($0.processIdentifier) } }
    }
    private var dock: AXUIElement? { hosts.last }
    static func attr(_ e: AXUIElement,_ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v : nil }
    static func children(_ e: AXUIElement) -> [AXUIElement] {
        var out=[AXUIElement]()
        for key in [kAXChildrenAttribute as String,"AXChildrenInNavigationOrder",kAXVisibleChildrenAttribute as String] {
            for c in attr(e,key) as? [AXUIElement] ?? [] where !out.contains(where:{ CFEqual($0,c) }) { out.append(c) }
        }
        return out
    }
    static func identifier(_ e: AXUIElement) -> String { attr(e,"AXIdentifier") as? String ?? "" }
    static func actions(_ e: AXUIElement) -> [String] { var a: CFArray?; AXUIElementCopyActionNames(e,&a); return a as? [String] ?? [] }
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p=attr(e,kAXPositionAttribute),let s=attr(e,kAXSizeAttribute) else { return nil }
        var pt=CGPoint.zero,sz=CGSize.zero
        AXValueGetValue(p as! AXValue,.cgPoint,&pt); AXValueGetValue(s as! AXValue,.cgSize,&sz)
        return CGRect(origin:pt,size:sz)
    }
    static func find(_ e: AXUIElement,id: String,depth: Int=0) -> [AXUIElement] {
        if identifier(e)==id { return [e] }
        guard depth<14 else { return [] }
        return children(e).flatMap { find($0,id:id,depth:depth+1) }
    }

    private var mcRoot: AXUIElement? {
        let all=hosts.flatMap { h -> [AXUIElement] in
            let top=Self.find(h,id:"mc"); if !top.isEmpty { return top }
            // WindowManager may expose mc.display groups directly under the application.
            return Self.find(h,id:"mc.display").isEmpty ? [] : [h]
        }
        return all.first(where:{ Self.isReady($0) }) ?? all.first
    }
    /// The mc group exists briefly before Mission Control is laid out; only count it as open once it has content or a frame.
    public var isOpen: Bool { guard let r=mcRoot else { return false }; return Self.isReady(r) }
    static func isReady(_ r: AXUIElement) -> Bool { !find(r,id:"mc.display").isEmpty }
    var mcPresent: Bool { mcRoot != nil }

    /// Whether the system Mission Control shortcut (symbolic hot key 32, default ⌃↑) is enabled. Missing entry = default = on.
    static var ctrlUpEnabled: Bool {
        let d=UserDefaults(suiteName:"com.apple.symbolichotkeys")?.dictionary(forKey:"AppleSymbolicHotKeys")
        return ((d?["32"] as? [String:Any])?["enabled"] as? Bool) ?? true
    }
    private func waitReady(_ seconds: TimeInterval) -> Bool {
        let end=Date().addingTimeInterval(seconds)
        while Date()<end { if isOpen { return true }; Thread.sleep(forTimeInterval:0.1) }
        return isOpen
    }
    /// What the last `open()` did, one entry per try ("app wait=2.5s → open after 1.2s"), for the restore log.
    public private(set) var lastOpenLog=[String]()
    /// Opens Mission Control and verifies it: it only counts as open once a display group (mc.display) is there
    /// (the Dock always exposes an empty zero-frame mc group). Tries `MissionControlOpening.attempts` in order
    /// (Mission Control.app, then ⌃↑ when that shortcut is on, then the app again) with growing waits and a pause in
    /// between; before every try it checks again that Mission Control is not open yet, so the ⌃↑ toggle can never
    /// close it. Throws `didNotOpenAfter` naming what was tried.
    public func open() throws {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard dock != nil else { throw Failure.dockMissing }
        lastOpenLog=[]
        if isOpen { lastOpenLog=["already open"]; return }
        let ctrlUp=Self.ctrlUpEnabled
        var tried=[MissionControlOpening.Method]()
        for (n,attempt) in MissionControlOpening.attempts(ctrlUpEnabled:ctrlUp).enumerated() {
            if n>0 {
                Thread.sleep(forTimeInterval:MissionControlOpening.backoff(after:n-1))
                if isOpen { lastOpenLog.append("open (late) before try \(n+1)"); Thread.sleep(forTimeInterval:0.5); return }
            }
            let started=Date()
            switch attempt.method {
            case .app:
                let cfg=NSWorkspace.OpenConfiguration(); cfg.activates=true
                NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:"/System/Applications/Mission Control.app"),configuration:cfg) { _,_ in }
            case .shortcut:
                let src=CGEventSource(stateID:.hidSystemState)
                for down in [true,false] { let e=CGEvent(keyboardEventSource:src,virtualKey:126,keyDown:down); e?.flags = .maskControl; e?.post(tap:.cghidEventTap) }
            }
            tried.append(attempt.method)
            if waitReady(attempt.wait) {
                lastOpenLog.append(String(format:"%@ wait=%.1fs → open after %.1fs",attempt.method.rawValue,attempt.wait,Date().timeIntervalSince(started)))
                // Let the layout finish so the + button and desk list are in place.
                Thread.sleep(forTimeInterval:0.5); return
            }
            lastOpenLog.append(String(format:"%@ wait=%.1fs → not open (mc group %@)",attempt.method.rawValue,attempt.wait,mcPresent ? "present, no displays" : "missing"))
        }
        throw Failure.didNotOpenAfter(tried:tried,ctrlUpEnabled:ctrlUp)
    }
    /// Closes Mission Control with Escape (falls back to toggling it once more).
    public func close() {
        guard isOpen else { return }
        let src=CGEventSource(stateID:.hidSystemState)
        CGEvent(keyboardEventSource:src,virtualKey:53,keyDown:true)?.post(tap:.cghidEventTap)
        CGEvent(keyboardEventSource:src,virtualKey:53,keyDown:false)?.post(tap:.cghidEventTap)
        let end=Date().addingTimeInterval(1.5)
        while Date()<end { if !isOpen { return }; Thread.sleep(forTimeInterval:0.1) }
        NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Mission Control.app"))
    }

    /// The Mission Control group of the display whose frame (top-left global coordinates) best matches `screen`.
    private func displayGroup(screen: CGRect) throws -> AXUIElement {
        guard let root=mcRoot else { throw Failure.didNotOpen }
        let groups=Self.find(root,id:"mc.display")
        let center=CGPoint(x:screen.midX,y:screen.midY)
        if let hit=groups.first(where:{ Self.frame($0)?.contains(center) == true }) { return hit }
        if groups.count==1 { return groups[0] }
        throw Failure.displayNotFound
    }
    private func spacesGroup(screen: CGRect) throws -> AXUIElement {
        let g=try displayGroup(screen:screen)
        return Self.find(g,id:"mc.spaces").first ?? g
    }
    /// The Space buttons Mission Control shows for that display (ordinary and full-screen alike), left to right.
    public func spaceButtons(screen: CGRect) throws -> [AXUIElement] {
        guard let list=Self.find(try spacesGroup(screen:screen),id:"mc.spaces.list").first else { throw Failure.listMissing }
        return Self.children(list).filter { (Self.attr($0,kAXRoleAttribute) as? String)==kAXButtonRole }
    }
    public func pressAdd(screen: CGRect) throws {
        guard let add=Self.find(try spacesGroup(screen:screen),id:"mc.spaces.add").first else { throw Failure.addButtonMissing }
        let e=AXUIElementPerformAction(add,kAXPressAction as CFString)
        guard e == .success else { throw Failure.axError(e.rawValue) }
    }
    public func remove(button: AXUIElement) throws {
        guard Self.actions(button).contains("AXRemoveDesktop") else { throw Failure.removeUnsupported }
        let e=AXUIElementPerformAction(button,"AXRemoveDesktop" as CFString)
        guard e == .success else { throw Failure.axError(e.rawValue) }
    }

    /// Read-only: opens Mission Control, waits until it is laid out, dumps the whole Dock AX tree while it stays open, then closes it.
    public func inspect() -> String {
        var lines=["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)","trusted=\(AXIsProcessTrusted())"]
        do { try open() } catch { lines.append(lk("调度中心未就绪：%@（仍然导出当前结构）", "\(error)")) }
        guard let dock=mcRoot ?? dock else { return (lines+[lk("找不到程序坞进程")]).joined(separator:"\n") }
        var count=0
        func walk(_ e: AXUIElement,_ d: Int) {
            guard count<4000 else { return }
            count+=1
            let role=Self.attr(e,kAXRoleAttribute) as? String ?? "?",sub=Self.attr(e,kAXSubroleAttribute) as? String ?? ""
            let title=Self.attr(e,kAXTitleAttribute) as? String ?? "",desc=Self.attr(e,kAXDescriptionAttribute) as? String ?? ""
            var names: CFArray?; AXUIElementCopyAttributeNames(e,&names)
            let f=Self.frame(e).map{ "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
            lines.append(String(repeating:"  ",count:d)+"\(role)/\(sub) id=\(Self.identifier(e)) title=\(title) desc=\(desc) actions=\(Self.actions(e).joined(separator:",")) [\(f)] attrs=\((names as? [String] ?? []).joined(separator:","))")
            if d<16 { for c in Self.children(e) { walk(c,d+1) } }
        }
        walk(dock,0)
        lines.append(lk("共 %@ 个元素；调度中心就绪=%@", "\(count)", "\(isOpen)"))
        close()
        return lines.joined(separator:"\n")
    }
}

/// Window ids per Space, read via CGWindowList + SkyLight membership. Used to make sure a Space is empty before removing it.
public enum SpaceOccupancy {
    public static func occupied(spaces backend: ReadOnlySpaces) -> Set<UInt64>? {
        guard let list=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return nil }
        let me=ProcessInfo.processInfo.processIdentifier
        var result=Set<UInt64>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int)==0,let id=w[kCGWindowNumber as String] as? UInt32,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me else { continue }
            if let b=w[kCGWindowBounds as String] as? [String:CGFloat],(b["Width"] ?? 0)<40 || (b["Height"] ?? 0)<40 { continue }
            guard let ids=try? backend.membership(windowID:id) else { return nil }   // unknown → treat everything as occupied
            if ids.count==1 { result.insert(ids[0]) }   // windows on all Spaces don't pin one
        }
        return result
    }
}
