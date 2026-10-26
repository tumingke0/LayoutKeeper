// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import CoreGraphics
import LayoutCore
import MacAdapters

/// 0.6.9 live record. While exactly one external monitor is attached and settled (no attach session pending or
/// running, nothing busy, no preview open), every `interval` seconds and shortly after a desk switch the external
/// windows are recorded with their desk identity and runtime identity (`LiveLayoutRecord`). The record is written,
/// debounced, to `<layouts>/live/<key>.json`, so it survives an app restart. When the recorded display goes away it is
/// frozen: the last record taken while it was still attached, plus the highest window number at that moment.
/// Scans that started before a display change and finish after it are discarded (generation counter), so nothing
/// read during or after the unplug can get into the record. Read only: it never moves a window.
final class LiveRecorder {
    static let interval: TimeInterval=20
    static let writeEvery: TimeInterval=10
    /// After an attach session closes, recording waits this long so the restore's own moves have landed.
    static let resumeGrace: TimeInterval=5
    private weak var model: Model?
    private let queue=DispatchQueue(label:"LayoutKeeper.live-record",qos:.utility)
    /// Own reader and Spaces handle: the background scan never shares state with restores or status checks.
    private let reader: AXWindows={ let w=AXWindows(spaces:ReadOnlySpaces()); w.remoteSearchTotal=1.5; w.remoteSearchPerApp=0.4; return w }()
    private var timer: Timer?
    private var kickWork: DispatchWorkItem?
    private var writeWork: DispatchWorkItem?
    private var scanning=false
    private var generation=0
    private(set) var latest: LiveLayoutRecord?
    private var lastWritten: LiveLayoutRecord?
    private var lastWriteAt=Date.distantPast
    private var resumeAt: Date?
    /// Chrome profile folder per window token (the session files are large; they are read again only for new tokens).
    private var profileCache=[String:String]()
    private var profileTried=Set<String>()
    /// True while an attach session is pending or open; set by the app delegate.
    var attachActive: () -> Bool = { false }
    /// Cost counters: background scan time, main-thread time in `accept` (of which Chrome profile loading). Every scan
    /// goes to the unified log (NSLog); a summary goes to the restore log every `statsEvery` scans, and any slow scan
    /// (background >300 ms or main >50 ms) right away.
    static let statsEvery=15
    private var stats=(n:0,scan:0.0,scanMax:0.0,main:0.0,mainMax:0.0,chrome:0.0,chromeMax:0.0,incomplete:0,carried:0)
    static let contentOnlyLogEvery: TimeInterval=600
    private var contentOnly=0
    private var contentOnlyLoggedAt=Date()
    /// 0.6.11 record trust (`LiveRecordTrust`): last wake, and the last reason a scan did not change the strip (logged
    /// once per change of reason).
    private var wokeAt: Date?
    private var untrustedReason: String?

    func start(model: Model) {
        self.model=model
        let t=Timer(timeInterval:Self.interval,repeats:true) { [weak self] _ in self?.tick(reason:"timer") }
        t.tolerance=2; timer=t; RunLoop.main.add(t,forMode:.common)
        kick(after:3,reason:"launch")
    }
    func kick(after delay: TimeInterval,reason: String) {
        kickWork?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.tick(reason:reason) }
        kickWork=work; DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    func woke() { wokeAt=Date(); kick(after:LiveRecordTrust.wakeGrace+1,reason:"after wake") }
    /// Screen locked or every display asleep: nothing the scan reads is the real layout.
    static func screenLocked() -> Bool {
        if let d=CGSessionCopyCurrentDictionary() as? [String:Any],(d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1 { return true }
        var count: UInt32=0
        guard CGGetOnlineDisplayList(0,nil,&count) == .success,count>0 else { return false }
        var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
        guard CGGetOnlineDisplayList(count,&ids,&count) == .success else { return false }
        return ids.prefix(Int(count)).allSatisfy{ CGDisplayIsAsleep($0) != 0 }
    }
    func attachSessionClosed() {
        resumeAt=Date().addingTimeInterval(Self.resumeGrace)
        kick(after:Self.resumeGrace+0.5,reason:"after attach")
    }
    private func pauseReason() -> String? {
        guard let model else { return "no model" }
        if RenderMode.snapshot || model.layoutStorageOverride != nil || model.emptyWindowTrial != nil { return "test mode" }
        if !model.trusted { return "no permission" }
        if attachActive() { return "attach session" }
        if let resumeAt,Date()<resumeAt { return "attach grace" }
        if model.busy || model.showingQuickRestore || model.autoSpaces.running { return "busy" }
        // LayoutKeeper's own arrangement switch (busy covers the confirmation): windows move with their screens.
        if model.ownArrangementChange() { return "arrangement change" }
        if MonitorRecognition.physicalExternalMonitors().count != 1 || model.currentExternalMonitor == nil { return "not exactly one external" }
        return nil
    }
    private func reportTrustReason(_ reason: String?,previous: LiveLayoutRecord?) {
        guard reason != untrustedReason else { return }
        if let why=reason { model?.logRestore("live-record: desk strip kept — \(why); keeping the last normal record"+(previous.map{ " from "+RestoreLog.stamp.string(from:$0.recordedAt)+" desks=[\($0.desks.map{ String($0.id) }.joined(separator:","))]" } ?? "")) }
        else if untrustedReason != nil { model?.logRestore("live-record: back to normal recording") }
        untrustedReason=reason
    }
    private func tick(reason: String) {
        guard !scanning,pauseReason() == nil,let monitor=model?.currentExternalMonitor else { return }
        let key=monitor.identity.key, token=monitor.runtimeDisplayToken, identity=monitor.identity, gen=generation
        let previousSame=latest.flatMap{ $0.key==key && !$0.frozen ? $0 : nil }
        if let why=LiveRecordTrust.preScanSkipReason(screenLocked:Self.screenLocked(),sinceWake:wokeAt.map{ Date().timeIntervalSince($0) }) {
            reportTrustReason(why,previous:previousSame)
            return
        }
        scanning=true
        queue.async { [weak self] in
            guard let self else { return }
            let t0=CFAbsoluteTimeGetCurrent()
            let snapshot=try? self.reader.scan(selectedDisplayToken:token,inspectionBudget:3)
            // Right after the scan: which windows the window server still has (for windows the scan could not read).
            let existing=Self.existingWindowTokens()
            let scanMs=(CFAbsoluteTimeGetCurrent()-t0)*1000
            DispatchQueue.main.async { self.scanning=false; self.accept(snapshot,existing:existing,generation:gen,key:key,token:token,identity:identity,reason:reason,scanMs:scanMs) }
        }
    }
    private func note(scanMs: Double,mainMs: Double,chromeMs: Double,windows: Int,reason: String) {
        NSLog("LayoutKeeper live-record scan: %.1f ms background, %.1f ms main (chrome %.1f ms), %d windows, %@",scanMs,mainMs,chromeMs,windows,reason)
        stats.n+=1; stats.scan+=scanMs; stats.main+=mainMs; stats.chrome+=chromeMs
        stats.scanMax=max(stats.scanMax,scanMs); stats.mainMax=max(stats.mainMax,mainMs); stats.chromeMax=max(stats.chromeMax,chromeMs)
        if scanMs>300 || mainMs>50 { model?.logRestore(String(format:"live-record: slow scan background=%.0fms main=%.0fms chrome=%.0fms windows=%d (%@)",scanMs,mainMs,chromeMs,windows,reason)) }
        if stats.n>=Self.statsEvery {
            let n=Double(stats.n)
            model?.logRestore(String(format:"live-record: cost over %d scans: background avg=%.0fms max=%.0fms; main avg=%.1fms max=%.1fms; chrome avg=%.1fms max=%.1fms; incomplete scans=%d (windows kept from the previous record: %d)",stats.n,stats.scan/n,stats.scanMax,stats.main/n,stats.mainMax,stats.chrome/n,stats.chromeMax,stats.incomplete,stats.carried))
            stats=(0,0,0,0,0,0,0,0,0)
        }
    }
    private func accept(_ snapshot: Snapshot?,existing: Set<String>?,generation gen: Int,key: String,token: String,identity: MonitorIdentity,reason: String,scanMs: Double) {
        guard let model else { return }
        guard let snapshot else { return }
        let m0=CFAbsoluteTimeGetCurrent()
        var chromeMs=0.0
        // A display change (or the start of an attach) while the scan ran: what it read may already be mid-unplug.
        guard gen==generation else { model.logRestore("live-record: scan discarded (display changed while scanning)"); return }
        if let why=pauseReason() { if why != "busy" { model.logRestore("live-record: scan discarded (\(why))") }; return }
        guard let m=model.currentExternalMonitor,m.identity.key==key,m.runtimeDisplayToken==token else { return }
        let previousSame=latest.flatMap { rec -> LiveLayoutRecord? in
            guard rec.key==key else { return nil }
            if !rec.frozen { return rec }
            let onExternal=snapshot.spaces.filter{ $0.displayToken==token && $0.kind == .ordinary }
            return onExternal.contains(where:{ sp in rec.desks.contains{ $0.matches(sp) } }) ? rec : nil
        }
        let verdict=LiveRecordTrust.assess(snapshot:snapshot,displayToken:token,previous:previousSame,screenLocked:Self.screenLocked(),sinceWake:wokeAt.map{ Date().timeIntervalSince($0) })
        reportTrustReason(verdict.reason,previous:previousSame)
        if case .skip=verdict { return }
        defer { note(scanMs:scanMs,mainMs:(CFAbsoluteTimeGetCurrent()-m0)*1000,chromeMs:chromeMs,windows:snapshot.windows.count,reason:reason) }
        let chrome=snapshot.windows.filter{ $0.selector.bundleID.hasPrefix("com.google.Chrome") }.map(\.token)
        if chrome.contains(where:{ profileCache[$0] == nil && !profileTried.contains($0) }) {
            let c0=CFAbsoluteTimeGetCurrent()
            if let resolver=ChromeProfiles.load() { for (t,p) in resolver.map(snapshot.windows) { profileCache[t]=p } }
            chromeMs=(CFAbsoluteTimeGetCurrent()-c0)*1000
            profileTried.formUnion(chrome)
        }
        let present=Set(snapshot.windows.map(\.token))
        profileCache=profileCache.filter{ present.contains($0.key) }; profileTried=profileTried.intersection(present)
        var keep: [DeskRef]?
        if case .keepDesks=verdict { keep=previousSame?.desks }
        guard let captured=LiveLayoutRecord.capture(key:key,monitor:identity,displayToken:token,snapshot:snapshot,browserProfiles:profileCache,keepingDesks:keep,builtInDesks:previousSame?.builtInDesks) else { return }
        // Windows this scan could not read but that are still open keep their previous entry (see carryingForward).
        // A window seen without any desk (not minimized or full screen) counts as not read: its desk is unknown.
        let (record,carried)=captured.carryingForward(latest,seenTokens:present.subtracting(LiveLayoutRecord.unplacedTokens(snapshot)),existingTokens:existing)
        if !carried.isEmpty { stats.carried+=carried.count; stats.incomplete+=1 }
        let previous=latest.flatMap{ $0.key==key ? $0 : nil }
        var why=LiveLayoutRecord.absenceReasons(snapshot)
        if let existing { for t in Set(previous?.structure.windows.keys.map{ $0 } ?? []).union(previous?.structure.elsewhere ?? []) where why[t]==nil && !present.contains(t) { why[t]=existing.contains(t) ? "not read this scan" : "closed" } }
        let changes=record.structuralChanges(from:previous,why:why)
        latest=record
        if !changes.isEmpty {
            let desks=Dictionary(grouping:record.windows,by:{ $0.desktopID ?? 0 }).sorted{ $0.key<$1.key }.map{ "\($0.key):\($0.value.count)" }.joined(separator:",")
            model.logRestore("live-record: updated (\(reason)) key=\(RestoreLog.key(key)) display=\(RestoreLog.d(token)) windows=\(record.windows.count) desks=[\(record.desks.map{ String($0.id) }.joined(separator:","))] perDesk=[\(desks)] elsewhere=\(record.elsewhere.count) changes=[\(changes.joined(separator:"; "))]"+(carried.isEmpty ? "" : " carried=\(carried.count)"))
        } else if let previous,!previous.sameContent(record) {
            // Only titles or frames changed: the file is updated, the log gets at most one summary per 10 minutes.
            contentOnly+=1
            if Date().timeIntervalSince(contentOnlyLoggedAt)>=Self.contentOnlyLogEvery {
                model.logRestore("live-record: \(contentOnly) title/position-only updates since the last summary (windows and desks unchanged; file kept current)")
                contentOnly=0; contentOnlyLoggedAt=Date()
            }
        }
        persist(force:false)
    }
    private func persist(force: Bool) {
        guard let model,let latest,let url=model.liveRecordURL(latest.key) else { return }
        if !force,let w=lastWritten,w.key==latest.key,w.sameContent(latest) { return }
        writeWork?.cancel(); writeWork=nil
        let wait=Self.writeEvery-Date().timeIntervalSince(lastWriteAt)
        if !force && wait>0 {
            let work=DispatchWorkItem { [weak self] in self?.persist(force:true) }
            writeWork=work; DispatchQueue.main.asyncAfter(deadline:.now()+wait,execute:work); return
        }
        do { try LiveRecordStore.save(latest,to:url); lastWritten=latest; lastWriteAt=Date() }
        catch { model.logRestore("live-record: write failed (\(String(describing:error).prefix(80)))") }
    }
    /// Screen configuration changed. Scans in flight are void; if the recorded display is gone, freeze the record.
    func screensChanged() {
        generation+=1
        guard let model,let latest,!latest.frozen else { return }
        let stillThere=MacEnvironment.displays().contains{ $0.token.caseInsensitiveCompare(latest.displayToken) == .orderedSame && $0.role == .external }
        guard !stillThere else { return }
        let now=Date()
        let frozen=latest.freezing(ceiling:Self.windowNumberCeiling(),at:now)
        self.latest=frozen
        persist(force:true)
        model.noteLiveFreeze(key:frozen.key,at:now)
        model.logRestore(String(format:"live-record: frozen at unplug key=%@ display=%@ windows=%d desks=[%@] ceiling=%@ recordAge=%.1fs",RestoreLog.key(frozen.key),RestoreLog.d(frozen.displayToken),frozen.windows.count,frozen.desks.map{ String($0.id) }.joined(separator:","),frozen.windowIDCeiling.map(String.init) ?? "-",now.timeIntervalSince(frozen.recordedAt)))
    }
    /// "pid:windowID" of every window the window server lists now (all desks, on or off screen), nil if unreadable.
    static func existingWindowTokens() -> Set<String>? {
        guard let list=CGWindowListCopyWindowInfo([.optionAll],kCGNullWindowID) as? [[String:Any]] else { return nil }
        return Set(list.compactMap{ w -> String? in
            guard let pid=(w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,let n=(w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return "\(pid):\(n)"
        })
    }
    /// Highest window number that exists now. Window numbers only grow within a login session, so any window above
    /// it was created later.
    static func windowNumberCeiling() -> UInt32? {
        guard let list=CGWindowListCopyWindowInfo([.optionAll],kCGNullWindowID) as? [[String:Any]] else { return nil }
        return list.compactMap{ ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }.max()
    }
}

/// The record an attach restores from: promoted from the live record when an attach session starts.
struct ArrivalLayout {
    var key: String
    var record: LiveLayoutRecord
    /// The frozen record belongs to the most recent unplug (so its desks on the built-in screen moved with it).
    var latestUnplug: Bool
    var activatedAt=Date()
    var sessionClosedAt: Date?
    /// Composed once per attach (with the snapshot of the first restore) so every step uses the same layout.
    var effective: EffectiveLayout?
    var savedAtWhenComposed: Date?
}

extension Model {
    static let arrivalLifetime: TimeInterval=300
    func liveRecordURL(_ key: String) -> URL? { layoutDirectory?.appendingPathComponent("live",isDirectory:true).appendingPathComponent("\(key).json") }
    private var lastUnplugURL: URL? { layoutDirectory?.appendingPathComponent("live",isDirectory:true).appendingPathComponent("last-unplug.json") }
    struct LastUnplug: Codable { var key: String; var at: Date }
    func noteLiveFreeze(key: String,at: Date) {
        guard let url=lastUnplugURL,let data=try? JSONEncoder().encode(LastUnplug(key:key,at:at)) else { return }
        try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? data.write(to:url,options:.atomic)
    }
    /// Attach session start: the live record of this layout key (frozen at the unplug, or the last one written if
    /// the app was not running then) becomes the arrival record for this attach.
    func activateArrival(for monitor: ConnectedMonitor,session id: Int) {
        let key=monitor.identity.key
        if let a=arrival,a.key==key,a.sessionClosedAt == nil { return }
        guard let url=liveRecordURL(key),let rec=LiveRecordStore.load(from:url),rec.key==key else {
            arrival=nil; logRestore("attach #\(id): no live record for \(RestoreLog.key(key)); saved layout only"); return
        }
        let last=lastUnplugURL.flatMap{ try? Data(contentsOf:$0) }.flatMap{ try? JSONDecoder().decode(LastUnplug.self,from:$0) }
        let latest=rec.frozenAt != nil && last?.key==key && last.map{ abs($0.at.timeIntervalSince(rec.frozenAt!))<1 } == true
        arrival=ArrivalLayout(key:key,record:rec,latestUnplug:latest)
        if let a=liveRecordURL(key)?.deletingPathExtension().appendingPathExtension("arrival.json") { try? LiveRecordStore.save(rec,to:a) }
        logRestore(String(format:"attach #%d: arrival record key=%@ frozen=%@ latestUnplug=%@ windows=%d desks=[%@] age=%.0fs",id,RestoreLog.key(key),rec.frozen ? "yes" : "no",latest ? "yes" : "no",rec.windows.count,rec.desks.map{ String($0.id) }.joined(separator:","),Date().timeIntervalSince(rec.frozenAt ?? rec.recordedAt)))
    }
    func arrivalSessionClosed() {
        if arrival != nil,arrival?.sessionClosedAt == nil { arrival?.sessionClosedAt=Date() }
        liveRecorder.attachSessionClosed()
    }
    /// The arrival record applies while its attach is current: during the session, then while desks are still
    /// missing for it, else for `arrivalLifetime` after the session. A layout saved after the record wins.
    func activeArrival(for monitor: MonitorIdentity,saved: MonitorLayoutRecord?) -> ArrivalLayout? {
        guard let a=arrival,a.key==monitor.key else { return nil }
        if let saved,saved.savedAt>(a.record.frozenAt ?? a.record.recordedAt) { logRestore("layout: saved layout is newer than the arrival record; arrival dropped"); arrival=nil; return nil }
        if let closed=a.sessionClosedAt,pendingSpacesNeeded == nil,Date().timeIntervalSince(closed)>Self.arrivalLifetime { arrival=nil; return nil }
        return a
    }
    /// The layout a restore works from: arrival record merged with the saved layout during an attach, else the saved layout.
    func effectiveLayout(monitor: MonitorIdentity,saved: MonitorLayoutRecord?,snapshot: Snapshot) -> EffectiveLayout? {
        guard let a=activeArrival(for:monitor,saved:saved) else {
            guard let saved else { return nil }
            return EffectiveLayout.compose(saved:saved,live:nil,monitor:monitor)
        }
        if let e=a.effective,a.savedAtWhenComposed==saved?.savedAt { return e }
        var live=a.record; live.monitor=monitor
        guard let e=EffectiveLayout.compose(saved:saved,live:live,monitor:monitor,snapshot:a.latestUnplug ? snapshot : nil) else { return nil }
        arrival?.effective=e; arrival?.savedAtWhenComposed=saved?.savedAt
        logRestoreLines(e.notes)
        return e
    }
}
