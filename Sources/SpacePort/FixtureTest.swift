// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import LayoutCore
import MacAdapters
import SpaceProbe

// Invoked only with --approved-fixture-test after explicit human authorization.
// All writes are confined to a new window owned by this process with this exact title.
final class FixtureTest {
    let model: Model
    let url: URL
    let phase: String
    var report: [String: Any]=[:]
    var fixture: NSWindow!
    var windowID: UInt32=0
    init(model: Model, url: URL, phase: String) { self.model=model; self.url=url; self.phase=phase }
    func persist() {
        do { try MacEnvironment.json(report).write(to:url,atomically:true,encoding:.utf8) }
        catch { fputs("Fixture report write failed: \(error)\n",stderr) }
    }
    func rect(_ f: Rect) -> [String:Double] { ["x":f.x,"y":f.y,"width":f.width,"height":f.height] }
    func frame() -> Rect {
        let f=fixture.frame, top=NSScreen.screens.first?.frame.maxY ?? 0
        return Rect(f.minX,top-f.maxY,f.width,f.height)
    }
    func cgFrame() -> Rect? {
        let rows=CGWindowListCopyWindowInfo(.optionIncludingWindow,windowID) as? [[String:Any]] ?? []
        guard let bounds=rows.first?[kCGWindowBounds as String] as? [String:Any],
              let x=bounds["X"] as? Double, let y=bounds["Y"] as? Double,
              let width=bounds["Width"] as? Double, let height=bounds["Height"] as? Double else { return nil }
        return Rect(x,y,width,height)
    }
    func sample() -> [String:Any] {
        var value: [String:Any]=["timestamp":ISO8601DateFormatter().string(from:Date()),"appKitFrameAXCoordinates":rect(frame()),"liveWindowID":fixture.windowNumber]
        do { value["spaceIDs"]=try model.spaces.membership(windowID:windowID) }
        catch { value["membershipError"]="\(error)" }
        let rows=CGWindowListCopyWindowInfo(.optionIncludingWindow,windowID) as? [[String:Any]] ?? []
        if let bounds=rows.first?[kCGWindowBounds as String] as? [String:Any] { value["cgWindowBounds"]=bounds }
        if let ax=try? model.windows.readWindow(token:"\(getpid()):\(windowID)") { value["axFrame"]=rect(ax.frame); value["axSpaceIDs"]=ax.spaceIDs; value["axOrdinary"]=ax.ordinary }
        return value
    }
    func wait(_ expectedSpace: UInt64, frame expectedFrame: Rect? = nil) -> Bool {
        for _ in 0..<20 {
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))
            guard fixture.windowNumber==Int(windowID) else { return false }
            if (try? model.spaces.membership(windowID:windowID)) == [expectedSpace],
               expectedFrame.map({frame().near($0) && cgFrame()?.near($0)==true}) ?? true { return true }
        }
        return false
    }
    func dispatch(_ spaceID: UInt64) -> [String:Any] {
        guard fixture.windowNumber==Int(windowID) else { return ["returnCode":-1,"detail":"Fixture was closed"] }
        var buffer=[CChar](repeating:0,count:512)
        let code=SPDispatchOwnedFixture(windowID,spaceID,&buffer,512)
        return ["returnCode":Int(code),"detail":String(cString:buffer),"targetRuntimeSpace":spaceID]
    }
    func run() {
        report=["testKind":"REAL macOS fixture integration","phase":phase,"timestamp":ISO8601DateFormatter().string(from:Date()),"scope":"Only new LayoutKeeper Fixture 1 owned by this process","pid":getpid(),"build":MacEnvironment.diagnostics(spaces:model.spaces)["build"] ?? "unknown","accessibilityTrusted":AXIsProcessTrusted(),"generalSpaceBackendEnabled":false,"stage":"creating fixture"]
        persist()
        model.createFixtures()
        guard model.fixtures.count==1, let f=model.fixtures.first, f.title=="LayoutKeeper Fixture 1", let id=UInt32(exactly:f.windowNumber) else { report["status"]="BLOCKED: invalid fixture"; persist(); finish(); return }
        fixture=f; windowID=id; report["runtimeWindowID"]=id
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.5))
        do {
            let membership=try model.spaces.membership(windowID:id)
            let initial=try model.windows.snapshot()
            guard membership.count==1, let source=initial.spaces.first(where:{$0.id==membership[0] && $0.kind == .ordinary}) else { throw LayoutError.readbackUnavailable }
            let beforeFrame=frame()
            report["sourceRuntimeSpace"]=source.id
            report["initial"]=sample(); persist()
            if phase=="all" || phase=="spaces" { testSpaces(source:source, snapshot:initial, original:beforeFrame) }
            if phase=="all" || phase=="ax" {
                guard try model.spaces.membership(windowID:id)==[source.id] else { report["axTest"]=["status":"BLOCKED: fixture is not back on its source Space"]; persist(); finish(); return }
                testAX(source:source)
            }
            report["final"]=sample(); report["stage"]="finished"; persist()
        } catch { report["status"]="FAILED: \(error)"; report["final"]=sample(); persist() }
        finish()
    }
    func testSpaces(source: Space, snapshot: Snapshot, original: Rect) {
        guard let target=snapshot.spaces.first(where:{$0.displayToken==source.displayToken && $0.kind == .ordinary && $0.id != source.id}) else {
            report["spacesTest"]=["status":"BLOCKED: no second ordinary Space on source display"]; persist(); return
        }
        var test: [String:Any]=["source":source.id,"target":target.id,"sameDisplay":true,"before":sample()]
        report["stage"]="dispatching outbound Space move"; report["spacesTest"]=test; persist()
        test["outboundDispatch"]=dispatch(target.id)
        let outbound=wait(target.id,frame:original)
        test["outboundVerified"]=outbound; test["afterOutbound"]=sample()
        report["spacesTest"]=test; report["stage"]="checking return move"; persist()
        let after=(try? model.spaces.membership(windowID:windowID)) ?? []
        if outbound || (after.count==1 && after != [source.id] && snapshot.spaces.contains(where:{$0.id==after[0] && $0.kind == .ordinary})) {
            test["returnDispatch"]=dispatch(source.id)
            test["returnVerified"]=wait(source.id,frame:original)
        } else { test["returnDispatch"]="Not needed: membership did not leave source, or could not be established"; test["returnVerified"]=after==[source.id] && frame().near(original) }
        test["afterReturn"]=sample()
        test["status"] = outbound && (test["returnVerified"] as? Bool)==true ? "PASS: actual outbound and return membership/position verified" : "FAIL: actual move was not verified"
        report["spacesTest"]=test; persist()
    }
    func testAX(source: Space) {
        var test: [String:Any]=["permissionAtTest":AXIsProcessTrusted(),"stage":"reading original fixture"]
        guard AXIsProcessTrusted() else { test["status"]="BLOCKED: Accessibility permission missing"; report["axTest"]=test; persist(); return }
        model.windows.writesApproved=true; defer { model.windows.writesApproved=false }
        var original: ObservedWindow?
        do {
            var captured=try model.windows.scan(onlyPID:getpid())
            captured.windows=captured.windows.filter{$0.token=="\(getpid()):\(windowID)" && $0.selector.title=="LayoutKeeper Fixture 1"}
            guard captured.windows.count==1, captured.windows[0].ordinary, captured.windows[0].spaceIDs==[source.id],
                  let display=captured.displays.first(where:{$0.token==source.displayToken}) else { throw LayoutError.readbackUnavailable }
            let w=captured.windows[0]; original=w
            let binding=DesktopBinding(label:lk("隔离测试"),role:display.role,spaceID:source.id,snapshot:captured)
            let (profile,issues)=try Planner.capture(location:lk("隔离实测"),snapshot:captured,bindings:[binding])
            guard profile.windows.count==1,issues.isEmpty else { throw LayoutError.readbackUnavailable }
            test["savedOriginal"]=rect(w.frame); test["before"]=sample()
            let requested=Rect(w.frame.x+60,w.frame.y+40,w.frame.width+80,w.frame.height+50)
            test["requestedChange"]=rect(requested); report["axTest"]=test; report["stage"]="AX fixture resize/move"; persist()
            try model.windows.setFrame(window:w,to:requested)
            var changed: ObservedWindow?
            for _ in 0..<20 {
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))
                if let actual=try model.windows.readWindow(token:w.token), actual.frame.near(requested),
                   actual.spaceIDs==[source.id], frame().near(requested), cgFrame()?.near(requested)==true { changed=actual; break }
            }
            test["changeVerified"]=changed != nil; test["afterChange"]=sample()
            guard let changed else { throw LayoutError.readbackUnavailable }
            var current=try model.windows.snapshot(); current.windows=[changed]
            let plan=try Planner.plan(profile:profile,snapshot:current,bindings:[binding],canMoveSpaces:false)
            test["previewStatus"]=plan.entries.map{$0.status.rawValue}
            let results=Restorer.execute(plan,windows:model.windows,spaces:model.spaces,approved:true,polls:20,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))})
            test["restoreResults"]=results.map{["outcome":$0.outcome.rawValue,"detail":$0.detail]}
            let settled=wait(source.id,frame:w.frame)
            test["windowServerRestoreVerified"]=settled
            let restored=try model.windows.readWindow(token:w.token)
            let passed=results.count==1 && results[0].outcome == .verified && settled && restored?.frame.near(w.frame)==true && restored?.spaceIDs==[source.id]
            test["afterRestore"]=sample(); test["status"]=passed ? "PASS: actual AX change and planned restore readback verified" : "FAIL: restore readback did not match original"
        } catch {
            test["status"]="FAIL: \(error)"; test["atFailure"]=sample()
            if let original, let current=try? model.windows.readWindow(token:original.token), current.selector==original.selector, current.spaceIDs==original.spaceIDs {
                do { try model.windows.setFrame(window:current,to:original.frame); test["cleanup"]=wait(source.id,frame:original.frame) ? "Original frame restored by AX" : "AX cleanup not verified" }
                catch { test["cleanup"]="AX cleanup failed: \(error)" }
            }
        }
        report["axTest"]=test; persist()
    }
    func finish() {
        model.message=lk("已批准的真实隔离测试结束，证据：%@", "\(url.path)")
        fputs("Fixture integration report: \(url.path)\n",stderr)
        NSApplication.shared.terminate(nil)
    }
}
