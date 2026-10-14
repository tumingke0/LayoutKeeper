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
        public var description: String {
            switch self {
            case .notTrusted: return "没有辅助功能权限"
            case .dockMissing: return "找不到程序坞进程"
            case .didNotOpen: return "调度中心没有打开"
            case .displayNotFound: return "调度中心里找不到这块屏幕"
            case .addButtonMissing: return "调度中心里找不到「+」按钮"
            case .listMissing: return "调度中心里找不到桌面列表"
            case .removeUnsupported: return "这个系统版本的调度中心不支持关闭桌面"
            case .axError(let e): return "辅助功能调用失败（\(e)）"
            }
        }
    }
    public init() {}

    private var dock: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first.map { AXUIElementCreateApplication($0.processIdentifier) }
    }
    static func attr(_ e: AXUIElement,_ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v : nil }
    static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
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
        guard depth<8 else { return [] }
        return children(e).flatMap { find($0,id:id,depth:depth+1) }
    }

    private var mcRoot: AXUIElement? { dock.flatMap { Self.find($0,id:"mc").first } }
    public var isOpen: Bool { mcRoot != nil }

    /// Opens Mission Control and waits until its AX tree appears.
    public func open(timeout: TimeInterval=2.5) throws {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        guard dock != nil else { throw Failure.dockMissing }
        if isOpen { return }
        NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Mission Control.app"))
        let end=Date().addingTimeInterval(timeout)
        while Date()<end { if isOpen { Thread.sleep(forTimeInterval:0.4); return }; Thread.sleep(forTimeInterval:0.1) }
        throw Failure.didNotOpen
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

    /// Read-only: opens Mission Control, dumps its AX tree (roles, identifiers, actions, frames), closes it again.
    public func inspect() -> String {
        do { try open() } catch { return "无法打开调度中心：\(error)" }
        defer { close() }
        guard let root=mcRoot else { return "调度中心已打开，但找不到 id=mc 的元素" }
        var lines=["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        func walk(_ e: AXUIElement,_ d: Int) {
            let role=Self.attr(e,kAXRoleAttribute) as? String ?? "?",desc=Self.attr(e,kAXDescriptionAttribute) as? String ?? ""
            let f=Self.frame(e).map{ "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
            lines.append(String(repeating:"  ",count:d)+"\(role) id=\(Self.identifier(e)) desc=\(desc) actions=\(Self.actions(e).joined(separator:",")) [\(f)]")
            if d<7 { for c in Self.children(e).prefix(30) { walk(c,d+1) } }
        }
        walk(root,0)
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
