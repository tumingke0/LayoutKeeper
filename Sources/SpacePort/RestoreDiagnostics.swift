// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

/// Verbose, privacy-safe logging for display events and restores (Diagnostics/restore-log.txt). Logging only:
/// nothing here changes what gets restored. No window titles, URLs or user names (see RestoreLog).
extension Model {
    func logRestoreLines(_ lines: [String]) { restoreLog?.append(lines) }
    static var appVersionText: (String,String) {
        let info=Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String ?? "?",info?["CFBundleVersion"] as? String ?? "?")
    }
    /// Session separator + full environment dump for one event.
    func logSession(_ event: String) {
        let (v,b)=Self.appVersionText
        logRestoreLines(RestoreLog.header(event:event,appVersion:v,build:b,os:systemBuildText)+environmentLines(label:"env"))
    }
    func environmentLines(label: String) -> [String] {
        var out=[String]()
        for s in NSScreen.screens {
            let id=(s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid=CGDisplayCreateUUIDFromDisplayID(id).map{ CFUUIDCreateString(nil,$0.takeRetainedValue())! as String }
            let f=s.frame, v=s.visibleFrame
            out.append("\(label) screen id=\(id) \(CGDisplayIsBuiltin(id) != 0 ? "builtIn" : "external") uuid=\(RestoreLog.d(uuid)) frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))) visible=(\(Int(v.minX)),\(Int(v.minY)) \(Int(v.width))x\(Int(v.height))) main=\(s == NSScreen.main) scale=\(s.backingScaleFactor)")
        }
        let displays=MacEnvironment.displays()
        if let all=try? spaces.spaces(displays:displays) {
            for disp in displays {
                var slot=0
                let list=all.filter{ $0.displayToken.caseInsensitiveCompare(disp.token) == .orderedSame }.map { sp -> String in
                    var tag: String
                    if sp.kind == .ordinary { slot+=1; tag="\(slot):\(sp.id)" } else { tag="\(sp.kind.rawValue):\(sp.id)" }
                    return sp.active ? tag+"*" : tag
                }.joined(separator:",")
                out.append("\(label) spaces \(RestoreLog.d(disp.token)) role=\(disp.role.rawValue) [\(list)]")
            }
            out.append("\(label) currentSpace=\(all.filter(\.active).map{ "\($0.id)@\(RestoreLog.d($0.displayToken))" }.joined(separator:",")) fullScreenOrUnknownSpaces=\(all.filter{ $0.kind != .ordinary }.count)")
        } else { out.append("\(label) spaces unreadable") }
        let physical=MonitorRecognition.physicalExternalMonitors()
        out.append("\(label) layoutMode=\(layoutMode) physicalExternal=\(physical.map{ "\($0.identity.key)@\(RestoreLog.d($0.runtimeDisplayToken))" }) effective=\(RestoreLog.key(currentExternalMonitor?.identity.key)) shared=\(currentExternalMonitor?.identity.isSharedExternal == true)")
        out.append("\(label) layout=\(layoutChoiceText)")
        let perMonitor=currentExternalMonitor.flatMap{ monitorPreferences.restore($0.identity.key) }
        out.append("\(label) trusted=\(trusted) globalMode=\(autoRestoreMode) perMonitor=\(perMonitor.map{"\($0)"} ?? "-") pausedUntil=\(pausedUntil.map{"\($0)"} ?? "-") busy=\(busyText) separateSpaces=\(SeparateSpaces.enabled) crossSpace=\(crossSpaceEnabled) autoAddSpaces=\(autoAddSpaces) autoRemoveSpaces=\(autoRemoveSpaces) pendingSpacesNeeded=\(pendingSpacesNeeded.map(String.init) ?? "-")")
        return out
    }
    /// Which saved layout is used now and why (per-monitor key vs the shared "office/home" layout).
    var layoutChoiceText: String {
        guard let m=currentExternalMonitor else { return "none (no single external monitor; externals=\(externalMonitors.count))" }
        let why=m.identity.isSharedExternal ? "sharedExternal mode: one layout for every external monitor" : "perMonitor mode: layout of this monitor"
        guard let r=externalRecord else { return "\(m.identity.key) (\(why)) — NO saved layout file" }
        let desks=Set(r.profile.windows.compactMap(\.desktopIndex))
        return "\(m.identity.key) (\(why)) savedAt=\(r.savedAt) windows=\(r.profile.windows.count) desktopsUsed=\(desks.sorted()) apps=\(Set(r.profile.windows.map(\.selector.bundleID)).sorted())"
    }
    var busyText: String { "restoring=\(restoring) selfTest=\(selfTestRunning) checkingCapture=\(checkingCapture) quickPanel=\(showingQuickRestore) autoSpacesRunning=\(autoSpaces.running)" }
    func logPlanDetail(trigger: String,plan: QuickRestorePlan,record: MonitorLayoutRecord?,snapshot: Snapshot?,displayToken: String?) {
        guard let record,let snapshot,let displayToken else { logRestore("plan-detail \(trigger) unavailable (no record/snapshot)"); return }
        let bundles=Set(record.profile.windows.map(\.selector.bundleID))
        let resolver=ChromeProfiles.load()
        let profiles=resolver?.map(snapshot.windows) ?? [:]
        let chromeLines=Self.chromeProfileLines(label:"snap \(trigger)",resolver:resolver,windows:snapshot.windows)
        logRestoreLines(RestoreLog.snapshotLines(snapshot,label:"snap \(trigger)",includeWindows:false)
            + ["snap \(trigger) chromeProfilesReadable=\(resolver != nil) status=\(ChromeProfiles.lastStatus) mapped=\(profiles.count) savedApps=\(bundles.count) liveWindowsOfSavedApps=\(snapshot.windows.filter{ bundles.contains($0.selector.bundleID) }.count)"]
            + chromeLines
            + RestoreLog.planDetail(trigger:trigger,plan:plan,record:record,snapshot:snapshot,displayToken:displayToken,browserProfiles:profiles))
    }
    /// One line per live Chrome window: which profile folder it resolved to, from which source, and why not.
    static func chromeProfileLines(label: String,resolver: ChromeProfileResolver?,windows: [ObservedWindow]) -> [String] {
        let chrome=windows.filter{ $0.selector.bundleID.hasPrefix("com.google.Chrome") }
        guard let resolver else { return chrome.map{ "\(label) chromeProfile \($0.token) -> - via=unknown(\(ChromeProfiles.lastStatus))" } }
        return resolver.resolveAll(chrome).map{ "\(label) chromeProfile \($0.0) -> \($0.1.logText)" }
    }
}
