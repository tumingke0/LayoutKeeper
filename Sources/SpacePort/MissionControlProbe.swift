// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import MacAdapters
import LayoutCore

/// Hidden diagnostic: `LayoutKeeper --dump-mission-control <out.txt>`. Read only (opens/closes Mission Control, never adds or removes Spaces).
enum MissionControlProbe {
    static func run(out: URL) {
        var log=[String](); let t0=Date()
        func L(_ s: String) { log.append(String(format:"%7.3f ",Date().timeIntervalSince(t0))+s) }
        func a(_ e: AXUIElement,_ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v : nil }
        func desc(_ e: AXUIElement) -> String {
            var pid: pid_t=0; AXUIElementGetPid(e,&pid)
            return "\(a(e,"AXRole") as? String ?? "?")/\(a(e,"AXSubrole") as? String ?? "") id=\(a(e,"AXIdentifier") as? String ?? "") title=\(a(e,"AXTitle") as? String ?? "") pid=\(pid)"
        }
        L("trusted=\(AXIsProcessTrusted()) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        guard let dockApp=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first else { L("no dock"); return write(log,out) }
        let dock=AXUIElementCreateApplication(dockApp.processIdentifier)
        func mc() -> AXUIElement? { (a(dock,"AXChildren") as? [AXUIElement] ?? []).first { (a($0,"AXIdentifier") as? String)=="mc" } }
        func state(_ tag: String) {
            guard let m=mc() else { L("\(tag): no mc"); return }
            let c=(a(m,"AXChildren") as? [AXUIElement])?.count ?? -1,n=(a(m,"AXChildrenInNavigationOrder") as? [AXUIElement])?.count ?? -1,v=(a(m,"AXVisibleChildren") as? [AXUIElement])?.count ?? -1
            let wins=(CGWindowListCopyWindowInfo([.optionOnScreenOnly],kCGNullWindowID) as? [[String:Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? Int32)==dockApp.processIdentifier }
            let layers=wins.map{ "\($0[kCGWindowLayer as String] ?? "?"):\($0[kCGWindowName as String] ?? "")" }
            L("\(tag): mc children=\(c) nav=\(n) visible=\(v) dockOnscreenWindows=\(wins.count) \(layers)")
        }
        func poll(_ tag: String,_ secs: Double) -> Bool {
            let end=Date().addingTimeInterval(secs)
            while Date()<end {
                RunLoop.current.run(until:Date().addingTimeInterval(0.25))
                state(tag)
                if let m=mc(),((a(m,"AXChildren") as? [AXUIElement])?.count ?? 0)>0 { return true }
            }
            return false
        }
        func hitTest(_ tag: String) {
            let sys=AXUIElementCreateSystemWide()
            let top=NSScreen.screens.first?.frame.maxY ?? 0
            for s in NSScreen.screens {
                for (fx,fy) in [(0.5,0.08),(0.5,0.5),(0.25,0.5)] {
                    let p=CGPoint(x:s.frame.minX+s.frame.width*fx,y:top-s.frame.maxY+s.frame.height*fy)
                    var el: AXUIElement?
                    let r=AXUIElementCopyElementAtPosition(sys,Float(p.x),Float(p.y),&el)
                    var chain=[String](); var cur=el
                    while let c=cur,chain.count<8 { chain.append(desc(c)); cur=a(c,"AXParent").map{ $0 as! AXUIElement } }
                    L("\(tag) hit \(Int(p.x)),\(Int(p.y)) r=\(r.rawValue) \(chain.joined(separator:" <- "))")
                }
            }
        }
        state("initial")
        L("step1 NSWorkspace.openApplication Mission Control.app")
        let cfg=NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:"/System/Applications/Mission Control.app"),configuration:cfg) { app,err in L("  open callback app=\(app?.bundleIdentifier ?? "nil") err=\(err.map{"\($0)"} ?? "nil")") }
        var ok=poll("after-open",2.5)
        hitTest("after-open")
        if !ok {
            for k in ["AXEnhancedUserInterface","AXManualAccessibility"] { L("set \(k) on dock -> \(AXUIElementSetAttributeValue(dock,k as CFString,kCFBooleanTrue).rawValue)") }
            ok=poll("after-enhanced",1.5)
        }
        if !ok {
            let esc=CGEventSource(stateID:.hidSystemState)
            for down in [true,false] { CGEvent(keyboardEventSource:esc,virtualKey:53,keyDown:down)?.post(tap:.cghidEventTap) }
            RunLoop.current.run(until:Date().addingTimeInterval(1))
            L("step2 post ctrl+up")
            for down in [true,false] { let e=CGEvent(keyboardEventSource:esc,virtualKey:126,keyDown:down); e?.flags = .maskControl; e?.post(tap:.cghidEventTap) }
            ok=poll("after-ctrlup",2.5)
            hitTest("after-ctrlup")
        }
        if ok, let m=mc() {
            var lines=[String]()
            func walk(_ e: AXUIElement,_ d: Int) { lines.append(String(repeating:"  ",count:d)+desc(e)+" actions=\({ var x: CFArray?; AXUIElementCopyActionNames(e,&x); return (x as? [String] ?? []).joined(separator:",") }())"); if d<10 { for c in a(e,"AXChildren") as? [AXUIElement] ?? [] { walk(c,d+1) } } }
            walk(m,0); L("TREE\n"+lines.joined(separator:"\n"))
        }
        let esc=CGEventSource(stateID:.hidSystemState)
        for down in [true,false] { CGEvent(keyboardEventSource:esc,virtualKey:53,keyDown:down)?.post(tap:.cghidEventTap) }
        RunLoop.current.run(until:Date().addingTimeInterval(1)); state("after-esc")
        L("driver.inspect():\n"+MissionControlDriver().inspect())
        write(log,out)
    }
    static func write(_ log: [String],_ out: URL) { try? log.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8) }
}

/// Hidden, user-approved test: `LayoutKeeper --test-add-remove-space <log.txt>`. Adds ONE Space on the external display
/// through the normal AutoSpacesRunner path, then removes that same new Space (one retry). Nothing else is touched.
enum AddRemoveSpaceTest {
    static func run(out: URL) {
        var log=[String](); let t0=Date()
        func L(_ s: String) { log.append(String(format:"%7.3f ",Date().timeIntervalSince(t0))+s); try? log.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8) }
        let spaces=ReadOnlySpaces(); let runner=AutoSpacesRunner(spaces:spaces)
        func census() -> (ext: [UInt64],bi: [UInt64],all: [Space])? {
            let d=MacEnvironment.displays()
            guard let all=try? spaces.spaces(displays:d) else { return nil }
            let e=Set(d.filter{ $0.role == .external }.map(\.token)),b=Set(d.filter{ $0.role == .builtIn }.map(\.token))
            return (all.filter{ e.contains($0.displayToken) && $0.kind == .ordinary }.map(\.id),all.filter{ b.contains($0.displayToken) && $0.kind == .ordinary }.map(\.id),all)
        }
        let ext=MacEnvironment.displays().filter{ $0.role == .external }
        L("trusted=\(AXIsProcessTrusted()) externals=\(ext.count)")
        guard ext.count==1,let before=census() else { L("ABORT: need exactly one external display and readable Spaces"); return }
        L("before: external=\(before.ext.count) \(before.ext) builtIn=\(before.bi.count) \(before.bi)")
        guard !AutoSpaces.fullScreenActive(before.all) else { L("ABORT: full-screen Space active"); return }
        let token=ext[0].token
        var done=false
        func finish() { done=true }
        runner.add(count:1,token:token) { r in
            L("add result: \(r)")
            guard case .success=r,let mid=census() else { finish(); return }
            L("after add: external=\(mid.ext.count) \(mid.ext) builtIn=\(mid.bi.count)")
            guard AutoSpaces.verifyAdded(before:before.ext,after:mid.ext),let new=mid.ext.first(where:{ !before.ext.contains($0) }) else { L("cannot identify new Space; NOT removing anything"); finish(); return }
            L("new Space id=\(new); removing it")
            func attempt(_ n: Int) {
                runner.remove(ids:[new],token:token) { r2 in
                    L("remove attempt \(n): \(r2)")
                    if case .failure=r2,n<2 { Thread.sleep(forTimeInterval:1); attempt(n+1); return }
                    if let end=census() {
                        L("final: external=\(end.ext.count) \(end.ext) builtIn=\(end.bi.count) \(end.bi)")
                        L(end.ext==before.ext && end.bi==before.bi ? "PASS: counts and ids identical to before" : "MISMATCH vs before")
                    }
                    finish()
                }
            }
            attempt(1)
        }
        let deadline=Date().addingTimeInterval(90)
        while !done && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
        if !done { L("TIMEOUT") }
    }
}
