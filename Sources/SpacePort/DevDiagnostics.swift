// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import LayoutCore
import MacAdapters
import ApplicationServices
import AppKit

/// Developer-only, read-only diagnostics (LAYOUTKEEPER_DEV_DIAG=1). Never moves windows or writes layouts.
enum DevDiagnostics {
    static func chromeProfiles(out: URL) {
        var lines=[String]()
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        do { _=try Data(contentsOf:root); lines.append("local state readable") } catch { lines.append("local state: \(error)") }
        lines.append("trusted=\(AXIsProcessTrusted())")
        let resolver=ChromeProfiles.load()
        lines.append("folders: "+(resolver?.folders.map{"\($0.id)=\($0.names.sorted())"}.joined(separator:"; ") ?? "none"))
        do {
            let s=try AXWindows(spaces:ReadOnlySpaces()).scan()
            let chrome=s.windows.filter{$0.selector.bundleID.hasPrefix("com.google.Chrome")}
            var unknown=0
            for w in chrome {
                let titleProfile=BrowserTitles.profile(w.selector.title,bundleID:w.selector.bundleID)
                let f=resolver?.folder(url:w.selector.document,titleProfile:titleProfile)
                if f==nil { unknown+=1 }
                let hits=resolver?.folders.filter{ f in w.selector.document.flatMap{$0.data(using:.utf8)}.map{f.session.range(of:$0) != nil} ?? false }.map(\.id) ?? []
                let host=w.selector.document.flatMap{URL(string:$0)?.host} ?? "-"
                lines.append("\(w.token) titleProfile=\(titleProfile ?? "-") host=\(host) hits=\(hits) -> \(f ?? "UNKNOWN")")
            }
            lines.append("chrome windows: \(chrome.count), unknown: \(unknown)")
        } catch { lines.append("scan failed: \(error)") }
        try? lines.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8)
    }
    static func dryRun(layout: URL,out: URL) {
        var lines=[String]()
        do {
            let record=try JSONDecoder().decode(MonitorLayoutRecord.self,from:Data(contentsOf:layout))
            guard let m=MonitorRecognition.externalMonitors().first else { throw LayoutError.readbackUnavailable }
            let s=try AXWindows(spaces:ReadOnlySpaces()).scan(selectedDisplayToken:m.runtimeDisplayToken)
            let resolver=ChromeProfiles.load()
            let map=resolver?.map(s.windows) ?? [:]
            lines.append("chrome status=\(ChromeProfiles.lastStatus)")
            lines+=Model.chromeProfileLines(label:"dry",resolver:resolver,windows:s.windows)
            let p=try QuickRestorePlanner.plan(record:record,monitor:record.monitor,displayToken:m.runtimeDisplayToken,snapshot:s,allowCrossSpace:true,browserProfiles:map)
            lines.append("monitor now: \(m.identity.key)  saved: \(record.monitor.key)  live windows: \(s.windows.count)")
            for i in p.items {
                let sp=record.profile.windows[i.savedIndex].browserProfile.map{" [\($0)]"} ?? ""
                lines.append("#\(i.savedIndex) \(i.bundleID)\(sp) | \(i.state) \(i.matchKind) token=\(i.chosenToken ?? "-")\(i.chosenToken.flatMap{map[$0]}.map{" [\($0)]"} ?? "") slot \(i.currentSlot.map(String.init) ?? "-")→\(i.targetSlot.map(String.init) ?? "-") cands=\(i.candidates.count) | \(i.reason)")
            }
            lines.append(p.summary)
            lines.append("--- restore-log format (privacy-safe) ---")
            lines+=RestoreLog.snapshotLines(s,label:"snap dry",includeWindows:false)
            lines+=RestoreLog.planDetail(trigger:"dry",plan:p,record:record,snapshot:s,displayToken:m.runtimeDisplayToken,browserProfiles:map)
            lines.append(RestoreLog.planSummary(trigger:"dry",plan:p))
            lines.append("auto subset: \(QuickRestorePlanner.autoSubset(p).entries.count) entries")
        } catch { lines.append("dry run failed: \(error)") }
        try? lines.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8)
    }
}

struct HarnessTransient: TransientFailure { var isTransient: Bool { true } }
/// Simulates a slow app: the first read of each listed window fails like an AX timeout.
final class SlowFirstRead: WindowBackend {
    let base: AXWindows; var pending: Set<String>; var injected=0
    init(_ base: AXWindows,slow: Set<String>) { self.base=base; pending=slow }
    func snapshot() throws -> Snapshot { try base.snapshot() }
    func setFrame(window: ObservedWindow,to frame: Rect) throws { try base.setFrame(window:window,to:frame) }
    func readWindow(token: String) throws -> ObservedWindow? {
        if pending.remove(token) != nil { injected+=1; throw HarnessTransient() }
        return try base.readWindow(token:token)
    }
}
extension DevDiagnostics {
    /// Moves ONLY windows whose title starts with "lk-test-"; the layout lives in memory / the out file, never in the user's library.
    static func restoreHarness(out: URL) {
        var lines=[String]()
        func log(_ s: String) { lines.append(s); try? lines.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8) }
        do {
            guard let m=MonitorRecognition.externalMonitors().first else { throw LayoutError.readbackUnavailable }
            let ax=AXWindows(spaces:ReadOnlySpaces()); ax.writesApproved=true
            func scanTest() throws -> Snapshot { var s=try ax.scan(selectedDisplayToken:m.runtimeDisplayToken); s.windows=s.windows.filter{$0.selector.title.hasPrefix("lk-test-")}; return s }
            let pre=try scanTest()
            guard pre.windows.count>=2,let ext=pre.displays.first(where:{$0.token==m.runtimeDisplayToken}) else { throw LayoutError.invalidProfile }
            for (i,w) in pre.windows.enumerated() {   // setup: place each test window at a distinct spot on the external screen
                try ax.setFrame(window:w,to:Rect(ext.visible.x+80+Double(i)*260,ext.visible.y+60+Double(i)*90,620+Double(i)*30,400))
            }
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.8))
            let s0=try scanTest()
            log("saved positions: "+s0.windows.map{"\($0.selector.title)@\($0.frame)"}.joined(separator:", "))
            let (record,_)=try ExternalLayoutCapture.capture(monitor:m.identity,displayToken:m.runtimeDisplayToken,snapshot:s0)
            log("captured \(record.profile.windows.count) windows")
            let builtin=s0.displays.first{$0.token != m.runtimeDisplayToken}
            for (i,w) in s0.windows.enumerated() {
                var f=w.frame
                if i==1,let b=builtin { f.x=b.visible.x+40; f.y=b.visible.y+40 } else { f.x+=150; f.y+=120; f.width-=60 }
                try ax.setFrame(window:w,to:f)
            }
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.8))
            let s1=try scanTest()
            log("after scramble: "+s1.windows.map{"\($0.selector.title)@\($0.frame)"}.joined(separator:", "))
            let pc=try QuickRestorePlanner.plan(record:record,monitor:m.identity,displayToken:m.runtimeDisplayToken,snapshot:s1,allowCrossSpace:true)
            for i in pc.items { log("plan(cross-Space on) #\(i.savedIndex) \(i.savedTitle): \(i.state) \(i.matchKind) | \(i.reason)") }
            log("auto subset entries (cross on): \(QuickRestorePlanner.autoSubset(pc).entries.count)")
            let p=try QuickRestorePlanner.plan(record:record,monitor:m.identity,displayToken:m.runtimeDisplayToken,snapshot:s1,allowCrossSpace:false)
            for i in p.items { log("plan #\(i.savedIndex) \(i.savedTitle): \(i.state) \(i.matchKind) | \(i.reason)") }
            log("auto subset entries: \(QuickRestorePlanner.autoSubset(p).entries.count)")
            let slow=SlowFirstRead(ax,slow:Set(s1.windows.prefix(1).map(\.token)))
            let report=ManualRestorer.execute(p.plan,windows:slow,approved:true,polls:8,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.12))},persist:{_ in})
            log("injected transient failures: \(slow.injected); failures: \(report.failures.map{"\($0.bundleID):\($0.reason)"})")
            for r in report.results { log("result \(r.title): \(r.outcome) \(r.detail)") }
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.5))
            let s2=try scanTest()
            var ok=true
            for w in s0.windows {
                guard let now=s2.windows.first(where:{$0.token==w.token}) else { ok=false; log("missing \(w.selector.title)"); continue }
                let d=max(abs(now.frame.x-w.frame.x),abs(now.frame.y-w.frame.y),abs(now.frame.width-w.frame.width),abs(now.frame.height-w.frame.height))
                if d>4 { ok=false }
                log("verify \(w.selector.title): saved \(w.frame) now \(now.frame) maxΔ=\(d)")
            }
            log(ok ? "HARNESS PASS" : "HARNESS FAIL")
        } catch { log("harness error: \(error)") }
    }
    /// Closes only "lk-test-" windows via their close button.
    static func closeTestWindows() {
        let ax=AXWindows(spaces:ReadOnlySpaces())
        guard let s=try? ax.scan() else { return }
        for app in NSWorkspace.shared.runningApplications where s.windows.contains(where:{$0.selector.bundleID==app.bundleIdentifier && $0.selector.title.hasPrefix("lk-test-")}) {
            let el=AXUIElementCreateApplication(app.processIdentifier); var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el,kAXWindowsAttribute as CFString,&v) == .success,let wins=v as? [AXUIElement] else { continue }
            for w in wins {
                var t: CFTypeRef?; AXUIElementCopyAttributeValue(w,kAXTitleAttribute as CFString,&t)
                guard (t as? String)?.hasPrefix("lk-test-")==true else { continue }
                var b: CFTypeRef?
                if AXUIElementCopyAttributeValue(w,kAXCloseButtonAttribute as CFString,&b) == .success,let b { AXUIElementPerformAction(b as! AXUIElement,kAXPressAction as CFString) }
            }
        }
    }
}
