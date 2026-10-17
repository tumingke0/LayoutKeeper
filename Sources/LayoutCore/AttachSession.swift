// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// One real monitor attach (or wake with a monitor attached) = one session = exactly one restore attempt that ends
/// with one `attach #N result=` line. Screen events are debounced (`settleInterval`). A session stays open across
/// cancellations (a new display event, the monitor changing while windows settle, another task being busy): those
/// send it back to waiting and the next settle starts the same session again. It closes only through `finish`.
///
/// A quick drop-and-return inside the debounce window (same monitor before and after) is a blip, not a new attach.
public struct AttachSession {
    public enum Decision: Equatable {
        case idle
        case wait(until: Date)
        /// Run the attempt for session `id` on `monitorKey`. `retry` = this session was started before and cancelled.
        case start(id: Int,monitorKey: String,retry: Bool)
        /// A session ended without an attempt being possible (unplugged / replaced by another monitor); log `line`.
        case closed(id: Int,line: String)
        /// Nothing to do; `note` explains why (blip, unplug, same monitor without wake).
        case ignored(note: String)
    }
    public struct Open: Equatable { public var id: Int; public var monitorKey: String; public var started: Bool; public var awaitingFollowUp=false }
    public let settleInterval: TimeInterval
    /// Monitor key at the last settled screen state (nil when settled with no external monitor).
    public private(set) var lastSettledKey: String?
    public private(set) var open: Open?
    public private(set) var pendingSince: Date?
    public private(set) var pendingWake=false
    private var fingerprint: String?
    private var sawDrop=false
    /// When the external monitor disappeared inside the current debounce window, and the longest such gap.
    private var dropStartedAt: Date?
    private var longestDrop: TimeInterval=0
    /// A gap at least this long is a real unplug/replug even when the same monitor (same display ID) comes back
    /// within the debounce window. Two same-model monitors without serial numbers can share a display ID, and a
    /// hand replug takes over a second; the 10/15 13:21 blip lasted 0.25 s.
    public static let realReplugGap: TimeInterval=1.0
    private var nextID=1
    public init(initialMonitorKey: String?,settleInterval: TimeInterval = 3,firstID: Int = 1) {
        lastSettledKey=initialMonitorKey; self.settleInterval=settleInterval; nextID=firstID
    }
    public var isPending: Bool { pendingSince != nil }
    /// Busy clock of the current attempt. An attempt starts when a display event (re)starts the session; busy
    /// requeues do not restart it. `noteBusy` returns true once the attempt has been refused for `busyTimeout`.
    public static let busyTimeout: TimeInterval=10
    public private(set) var busySince: Date?
    public mutating func noteBusy(at time: Date) -> Bool {
        let since=busySince ?? time; busySince=since
        return time.timeIntervalSince(since)>=Self.busyTimeout
    }
    public mutating func notBusy() { busySince=nil }
    /// A display event or wake. `monitorKeyNow` is the external monitor visible right now (nil if none), used to tell a blip.
    public mutating func note(wake: Bool,at time: Date,fingerprint fp: String,monitorKeyNow: String?) {
        if pendingSince == nil { sawDrop=false; dropStartedAt=nil; longestDrop=0 }
        busySince=nil
        pendingSince=time; fingerprint=fp
        if wake { pendingWake=true }
        if monitorKeyNow != lastSettledKey { sawDrop=true }
        if monitorKeyNow == nil { if dropStartedAt == nil { dropStartedAt=time } }
        else if let start=dropStartedAt { longestDrop=max(longestDrop,time.timeIntervalSince(start)); dropStartedAt=nil }
    }
    /// Send an open session back to waiting (cancelled, busy). The next settle restarts it.
    public mutating func requeue(at time: Date,delay: TimeInterval? = nil) {
        guard open != nil else { return }
        pendingSince=time+(delay ?? settleInterval)-settleInterval
    }
    public mutating func evaluate(at time: Date,fingerprint current: String,monitorKey: String?) -> Decision {
        guard let since=pendingSince else { return .idle }
        if let fp=fingerprint,current != fp { fingerprint=current; pendingSince=time; return .wait(until:time+settleInterval) }
        fingerprint=current
        if time<since+settleInterval { return .wait(until:since+settleInterval) }
        pendingSince=nil
        let woke=pendingWake, drop=sawDrop, previous=lastSettledKey, replugged=longestDrop>=Self.realReplugGap
        pendingWake=false; sawDrop=false; dropStartedAt=nil; longestDrop=0; lastSettledKey=monitorKey
        if var o=open {
            guard let monitorKey else { open=nil; return .closed(id:o.id,line:"attach #\(o.id) result=skipped reason=unplugged-before-restore") }
            if monitorKey == o.monitorKey { let retry=o.started; o.started=true; open=o; return .start(id:o.id,monitorKey:monitorKey,retry:retry) }
            // Another monitor replaced it: close the old one; the new monitor is a new attach.
            open=nil
            let line="attach #\(o.id) result=skipped reason=replaced-by-other-monitor"
            let id=openNew(monitorKey)
            return .closed(id:o.id,line:line+" next=#\(id)")
        }
        guard let monitorKey else { return .ignored(note:"settled with no single external monitor (unplug: nothing to restore)") }
        if monitorKey != previous || woke || replugged { _=openNew(monitorKey); open!.started=true; return .start(id:open!.id,monitorKey:monitorKey,retry:false) }
        return .ignored(note:drop ? "blip ignored — screens dropped and came back within \(Int(settleInterval))s on the same monitor; not a new plug-in"
                                  : "same monitor, no wake (resolution/arrangement change); not a new plug-in")
    }
    /// After `.closed(..., next=#N)` the replacing session is open but not started yet: start it.
    public mutating func startOpened() -> Decision {
        guard var o=open,!o.started else { return .idle }
        o.started=true; open=o; return .start(id:o.id,monitorKey:o.monitorKey,retry:false)
    }
    private mutating func openNew(_ key: String) -> Int { let id=nextID; nextID+=1; open=Open(id:id,monitorKey:key,started:false); return id }
    /// The restore started an asynchronous follow-up (auto-add desktops, then restore again): the session stays open
    /// and owns that follow-up until `followUpArrived` or `finish` (e.g. a timeout).
    public mutating func beginFollowUp(id: Int) -> Bool {
        guard var o=open,o.id==id else { return false }
        o.awaitingFollowUp=true; open=o; return true
    }
    /// True exactly once, for the session that is waiting on it; a late or foreign arrival returns false.
    public mutating func followUpArrived(id: Int) -> Bool {
        guard var o=open,o.id==id,o.awaitingFollowUp else { return false }
        o.awaitingFollowUp=false; open=o; return true
    }
    public var awaitingFollowUp: Bool { open?.awaitingFollowUp == true }
    /// Ends the open session with its single result line. Returns nil if `id` is not the open session.
    public mutating func finish(id: Int,result: String) -> String? {
        guard let o=open,o.id==id else { return nil }
        open=nil; busySince=nil; return "attach #\(id) result=\(result)"
    }
}

/// Per-window outcome across the steps of one attach (retry for slow apps, restore again after adding desktops).
/// The latest step decides a window's state, so a window moved twice counts once, and a retried window that
/// succeeded is not also counted as failed.
public struct RestoreTally: Equatable {
    public private(set) var verified=Set<String>()
    public private(set) var failed=Set<String>()
    public init() {}
    public mutating func add(verified v: Set<String>,failed f: Set<String>) {
        verified=verified.subtracting(f).union(v); failed=failed.subtracting(v).union(f.subtracting(v))
    }
    public mutating func add(_ other: RestoreTally) { add(verified:other.verified,failed:other.failed) }
    public var restored: Int { verified.count }
    public var attempted: Int { verified.count+failed.count }
}
