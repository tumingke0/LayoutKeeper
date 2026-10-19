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
        if MonitorRecognition.physicalExternalMonitors().count != 1 || model.currentExternalMonitor == nil { return "not exactly one external" }
        return nil
    }
    private func tick(reason: String) {
        guard !scanning,pauseReason() == nil,let monitor=model?.currentExternalMonitor else { return }
        let key=monitor.identity.key, token=monitor.runtimeDisplayToken, identity=monitor.identity, gen=generation
        scanning=true
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot=try? self.reader.scan(selectedDisplayToken:token,inspectionBudget:3)
            DispatchQueue.main.async { self.scanning=false; self.accept(snapshot,generation:gen,key:key,token:token,identity:identity,reason:reason) }
        }
    }
    private func accept(_ snapshot: Snapshot?,generation gen: Int,key: String,token: String,identity: MonitorIdentity,reason: String) {
        guard let model else { return }
        guard let snapshot else { return }
        // A display change (or the start of an attach) while the scan ran: what it read may already be mid-unplug.
        guard gen==generation else { model.logRestore("live-record: scan discarded (display changed while scanning)"); return }
        if let why=pauseReason() { if why != "busy" { model.logRestore("live-record: scan discarded (\(why))") }; return }
        guard let m=model.currentExternalMonitor,m.identity.key==key,m.runtimeDisplayToken==token else { return }
        let chrome=snapshot.windows.filter{ $0.selector.bundleID.hasPrefix("com.google.Chrome") }.map(\.token)
        if chrome.contains(where:{ profileCache[$0] == nil && !profileTried.contains($0) }) {
            if let resolver=ChromeProfiles.load() { for (t,p) in resolver.map(snapshot.windows) { profileCache[t]=p } }
            profileTried.formUnion(chrome)
        }
        let present=Set(snapshot.windows.map(\.token))
        profileCache=profileCache.filter{ present.contains($0.key) }; profileTried=profileTried.intersection(present)
        guard let record=LiveLayoutRecord.capture(key:key,monitor:identity,displayToken:token,snapshot:snapshot,browserProfiles:profileCache) else { return }
        let changed=latest.map{ $0.key != key || !$0.sameContent(record) } ?? true
        latest=record
        if changed {
            let desks=Dictionary(grouping:record.windows,by:{ $0.desktopID ?? 0 }).sorted{ $0.key<$1.key }.map{ "\($0.key):\($0.value.count)" }.joined(separator:",")
            model.logRestore("live-record: updated (\(reason)) key=\(RestoreLog.key(key)) display=\(RestoreLog.d(token)) windows=\(record.windows.count) desks=[\(record.desks.map{ String($0.id) }.joined(separator:","))] perDesk=[\(desks)] elsewhere=\(record.elsewhere.count)")
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
