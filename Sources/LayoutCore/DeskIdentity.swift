// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// Desk identity, the live record, and how a restore decides which desk each group of windows goes to (0.6.9).
//
// macOS keeps a desktop's ManagedSpaceID and uuid when the monitor is unplugged: the desktop moves to the built-in
// screen with its windows, and goes back to the monitor (with its windows) when the same monitor returns. Ordinals
// ("desk 3") do not survive this: desks get added or removed on either side, so ordinal-only restore moved windows
// that were already in place (10/17) and piled several groups onto the last desk (10/19).

/// One ordinary desktop, by identity.
public struct DeskRef: Codable, Equatable, Hashable {
    public var id: UInt64; public var uuid: String?
    public init(id: UInt64, uuid: String?) { self.id=id; self.uuid=uuid }
    public init(_ space: Space) { id=space.id; uuid=space.uuid }
    /// uuid when both sides have one (IDs can be reused after a logout, uuids are not); otherwise the ID.
    public func matches(_ space: Space) -> Bool {
        if let uuid,let other=space.uuid { return uuid==other }
        return id==space.id
    }
}

extension SavedWindow {
    public var desk: DeskRef? { desktopID.map{ DeskRef(id:$0,uuid:desktopUUID) } }
    /// Windows with the same key were on the same desktop. uuid, else ID, else the per-desktop label of old records.
    public var groupKey: String {
        if let u=desktopUUID,!u.isEmpty { return "u:"+u }
        if let id=desktopID { return "d:\(id)" }
        return "l:"+desktopLabel
    }
}

/// A window that was on another display (the built-in screen) when the record was taken. The live record wins for
/// the windows it knows about, so a saved entry for one of these is not dragged back to the monitor.
public struct ElsewhereWindow: Codable, Equatable {
    public var selector: WindowSelector; public var runtime: RuntimeWindowIdentity; public var browserProfile: String?
    public init(selector: WindowSelector, runtime: RuntimeWindowIdentity, browserProfile: String? = nil) { self.selector=selector; self.runtime=runtime; self.browserProfile=browserProfile }
}

/// What was on the external monitor, recorded continuously while it is attached and settled. Frozen at a real unplug
/// (the last record taken while still attached), then used for the next attach together with the saved layout.
public struct LiveLayoutRecord: Codable, Equatable {
    public var schemaVersion=1
    public var key: String
    public var monitor: MonitorIdentity
    public var displayToken: String
    public var recordedAt: Date
    /// External windows, in desk order. Each has desktopIndex/desktopID/desktopUUID and its runtime identity.
    public var windows: [SavedWindow]
    /// The monitor's ordinary desktops in order, empty ones included.
    public var desks: [DeskRef]
    public var elsewhere: [ElsewhereWindow]
    /// Highest CGWindowID that existed at the unplug (window IDs only grow within a login session). Windows above
    /// it were created after the unplug and never were on the monitor.
    public var windowIDCeiling: UInt32?
    public var frozenAt: Date?
    /// 0.6.11: the built-in screen's own ordinary desktops at the last normal record. With the lid closed macOS moves
    /// them onto the external monitor (10/21 09:00:53); they are not part of its desk strip.
    public var builtInDesks: [DeskRef]?
    public init(key: String, monitor: MonitorIdentity, displayToken: String, recordedAt: Date, windows: [SavedWindow], desks: [DeskRef], elsewhere: [ElsewhereWindow] = []) {
        self.key=key; self.monitor=monitor; self.displayToken=displayToken; self.recordedAt=recordedAt; self.windows=windows; self.desks=desks; self.elsewhere=elsewhere
    }
    public var frozen: Bool { frozenAt != nil }
    public func validate() throws {
        guard schemaVersion==1,!key.isEmpty,windows.allSatisfy({ $0.displayRole == .external && $0.normalizedFrame.valid && $0.runtime != nil && $0.desktopID != nil }) else { throw LayoutError.invalidProfile }
    }
    /// Comparable content (ignores when it was taken), so an unchanged scan does not rewrite the file.
    public func sameContent(_ other: LiveLayoutRecord) -> Bool {
        var a=self,b=other; a.recordedAt = .distantPast; b.recordedAt = .distantPast; return a==b
    }
    public func freezing(ceiling: UInt32?, at date: Date) -> LiveLayoutRecord {
        var r=self; r.frozenAt=date; r.windowIDCeiling=ceiling; return r
    }
    /// Builds the record from one snapshot. Only ordinary, visible, single-desk windows on `displayToken` are
    /// recorded; windows on other displays go to `elsewhere`. Unlike a saved layout, windows with equal titles are
    /// kept: the runtime identity tells them apart.
    ///
    /// `keepingDesks` (lid closed, see `LiveRecordTrust`): the strip stays exactly this list; only windows on these
    /// desks are recorded at their position, every other window counts as elsewhere. `builtInDesks` is taken from
    /// the snapshot when the built-in screen is there, else the given (carried) value is kept.
    public static func capture(key: String, monitor: MonitorIdentity, displayToken: String, snapshot s: Snapshot,
                               browserProfiles: [String:String] = [:], at date: Date = Date(),
                               keepingDesks: [DeskRef]? = nil, builtInDesks carried: [DeskRef]? = nil) -> LiveLayoutRecord? {
        guard let display=s.displays.first(where:{ $0.token==displayToken && $0.role == .external }),display.visible.valid else { return nil }
        let onDisplay=s.spaces.filter{ $0.displayToken==displayToken && $0.kind == .ordinary }
        guard !onDisplay.isEmpty else { return nil }
        let strip=keepingDesks ?? onDisplay.map(DeskRef.init)
        guard !strip.isEmpty else { return nil }
        var windows=[SavedWindow](),elsewhere=[ElsewhereWindow]()
        for w in s.windows where WindowMatcher.eligible(w,s) && !w.selector.bundleID.isEmpty {
            let runtime=RuntimeWindowIdentity(token:w.token,processStartedAt:w.processStartedAt)
            guard let space=onDisplay.first(where:{ $0.id==w.spaceIDs[0] }),let slot=strip.firstIndex(where:{ $0.same(DeskRef(space)) }) else {
                elsewhere.append(ElsewhereWindow(selector:w.selector,runtime:runtime,browserProfile:browserProfiles[w.token])); continue
            }
            let normalized=w.frame.normalized(in:display.visible)
            guard normalized.valid,normalized.width<=4,normalized.height<=4 else { continue }
            var saved=SavedWindow(selector:w.selector,displayRole:.external,desktopLabel:"desk-\(space.id)",normalizedFrame:normalized,desktopIndex:slot+1,desktopID:space.id,desktopUUID:space.uuid)
            saved.browserProfile=browserProfiles[w.token]; saved.runtime=runtime
            windows.append(saved)
        }
        windows.sort{ ($0.desktopIndex ?? 0,$0.runtime?.token ?? "")<($1.desktopIndex ?? 0,$1.runtime?.token ?? "") }
        var r=LiveLayoutRecord(key:key,monitor:monitor,displayToken:displayToken,recordedAt:date,windows:windows,desks:strip,elsewhere:elsewhere)
        let builtIn=Set(s.displays.filter{ $0.role == .builtIn }.map(\.token))
        r.builtInDesks=builtIn.isEmpty ? carried : s.spaces.filter{ builtIn.contains($0.displayToken) && $0.kind == .ordinary }.map(DeskRef.init)
        return r
    }
}

extension LiveLayoutRecord {
    /// What a restore depends on: the display, its desks, which windows (runtime identity) sit on which desk, and
    /// which windows were on another display. Titles and frames are left out: they change all the time (a chat or
    /// terminal title, a moved window) without changing what goes where.
    public struct Structure: Equatable {
        public var display: String
        public var desks: [DeskRef]
        public var windows: [String:DeskRef]
        public var elsewhere: Set<String>
    }
    public var structure: Structure {
        var w=[String:DeskRef]()
        for x in windows { if let t=x.runtime?.token,let d=x.desk { w[t]=d } }
        return Structure(display:displayToken.uppercased(),desks:desks,windows:w,elsewhere:Set(elsewhere.map(\.runtime.token)))
    }
    /// Structural differences from `old` as short log tokens (bundle ID and window token only, never titles).
    /// Empty when only titles, frames or timestamps changed.
    public func structuralChanges(from old: LiveLayoutRecord?, why: [String:String] = [:]) -> [String] {
        guard let old else { return ["first record"] }
        let a=old.structure,b=structure
        if a==b { return [] }
        var out=[String]()
        if a.display != b.display { out.append("display changed") }
        if a.desks != b.desks { out.append("desks [\(a.desks.map{ String($0.id) }.joined(separator:","))]→[\(b.desks.map{ String($0.id) }.joined(separator:","))]") }
        func bundle(_ t: String) -> String {
            windows.first{ $0.runtime?.token==t }?.selector.bundleID ?? elsewhere.first{ $0.runtime.token==t }?.selector.bundleID
                ?? old.windows.first{ $0.runtime?.token==t }?.selector.bundleID ?? old.elsewhere.first{ $0.runtime.token==t }?.selector.bundleID ?? "?"
        }
        for t in b.windows.keys.sorted() where a.windows[t]==nil { out.append("+\(bundle(t)) \(t) desk \(b.windows[t]!.id)") }
        func because(_ t: String) -> String { why[t].map{ " (\($0))" } ?? "" }
        for t in a.windows.keys.sorted() where b.windows[t]==nil { out.append("-\(bundle(t)) \(t) desk \(a.windows[t]!.id)"+(b.elsewhere.contains(t) ? "" : because(t))) }
        for t in a.windows.keys.sorted() { if let x=a.windows[t],let y=b.windows[t],x != y { out.append("\(bundle(t)) \(t) desk \(x.id)→\(y.id)") } }
        for t in b.elsewhere.subtracting(a.elsewhere).sorted() { out.append("+elsewhere \(bundle(t)) \(t)") }
        for t in a.elsewhere.subtracting(b.elsewhere).sorted() { out.append("-elsewhere \(bundle(t)) \(t)"+(b.windows[t] != nil ? "" : because(t))) }
        return out
    }
    /// A scan is not always complete: windows on desks that are not shown are found through a time-limited search,
    /// and an app that is slow to answer is skipped (`AXWindows` reports such windows as unknown, never as closed).
    /// So a window that the previous record had, that this scan did not see at all, and that the window server still
    /// lists (`existingTokens`, "pid:windowID") is still open: keep its previous entry, as long as its desk still
    /// exists. A window the scan did see (even minimized, full screen or on several desks) follows the new scan, and a
    /// window the window server no longer lists is gone. Returns the record and the carried tokens.
    /// Why a window the scan saw is not in the record, for the log ("minimized", "no desk", …; nil = not seen).
    public static func absenceReasons(_ s: Snapshot) -> [String:String] {
        var out=[String:String]()
        for w in s.windows {
            if w.minimized { out[w.token]="minimized" } else if w.fullScreen { out[w.token]="full screen" }
            else if !w.ordinary { out[w.token]="not a standard window" } else if w.spaceIDs.isEmpty { out[w.token]="no desk reported" }
            else if w.spaceIDs.count>1 { out[w.token]="on several desks" } else if !w.frame.valid { out[w.token]="no frame" }
        }
        return out
    }
    /// Tokens the scan saw but could not place: a window whose desk the system did not report (an empty desk list,
    /// which happens for a moment during a desk switch and for some apps' windows) is unknown, not moved.
    public static func unplacedTokens(_ s: Snapshot) -> Set<String> {
        Set(s.windows.filter{ $0.ordinary && !$0.minimized && !$0.fullScreen && $0.spaceIDs.isEmpty }.map(\.token))
    }
    public func carryingForward(_ previous: LiveLayoutRecord?, seenTokens: Set<String>, existingTokens: Set<String>?) -> (record: LiveLayoutRecord, carried: [String]) {
        guard let previous,let existingTokens,previous.key==key,previous.displayToken.caseInsensitiveCompare(displayToken) == .orderedSame,!previous.frozen else { return (self,[]) }
        var r=self, carried=[String]()
        let have=Set(windows.compactMap{ $0.runtime?.token }).union(elsewhere.map(\.runtime.token))
        func keep(_ t: String) -> Bool { !seenTokens.contains(t) && !have.contains(t) && existingTokens.contains(t) }
        for var w in previous.windows {
            guard let t=w.runtime?.token,keep(t),let d=w.desk,let i=desks.firstIndex(where:{ $0.id==d.id && ($0.uuid == nil || d.uuid == nil || $0.uuid==d.uuid) }) else { continue }
            w.desktopIndex=i+1; r.windows.append(w); carried.append(t)
        }
        for e in previous.elsewhere where keep(e.runtime.token) { r.elsewhere.append(e); carried.append(e.runtime.token) }
        if !carried.isEmpty { r.windows.sort{ ($0.desktopIndex ?? 0,$0.runtime?.token ?? "")<($1.desktopIndex ?? 0,$1.runtime?.token ?? "") } }
        return (r,carried)
    }
}

public enum LiveRecordStore {
    public static func load(from url: URL) -> LiveLayoutRecord? {
        guard let data=try? Data(contentsOf:url),let r=try? JSONDecoder().decode(LiveLayoutRecord.self,from:data),(try? r.validate()) != nil else { return nil }
        return r
    }
    public static func save(_ record: LiveLayoutRecord, to url: URL) throws {
        try record.validate()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try encoder.encode(record).write(to:url,options:.atomic)
    }
}

/// Where a window of the effective layout came from.
public enum WindowSource: String, Codable {
    /// In the live record taken just before the unplug.
    case live
    /// Only in the saved layout (not on the monitor at the unplug, or the live record could not see it).
    case saved
    /// Saved window whose title changed, recognised because it still sits on its own desk that the unplug moved to
    /// the built-in screen (see `EffectiveLayout.compose`).
    case savedDeskEvidence
    /// Not in either record, but provably was on one of the monitor's desks at the unplug (see `compose`).
    case companion
    public var logName: String { rawValue }
}

/// Extra facts for the planner when the layout comes from a live record.
public struct RestoreContext: Equatable {
    /// One per window of the record the planner gets, same order.
    public var sources: [WindowSource]
    /// Desks of the frozen live record (the monitor's desks at the unplug).
    public var frozenDesks: [DeskRef]
    /// The one desk strip this restore reproduces (0.6.11): the live record's when the layout comes from it, else the
    /// saved layout's. Windows of the other record only take a position through their own desktop (strictly same).
    public var strip: DeskStrip?
    public init(sources: [WindowSource], frozenDesks: [DeskRef] = [], strip: DeskStrip? = nil) { self.sources=sources; self.frozenDesks=frozenDesks; self.strip=strip }
    public func source(_ i: Int) -> WindowSource { sources.indices.contains(i) ? sources[i] : .saved }
}

/// The layout a restore after an attach works from: the frozen live record merged with the saved layout.
///
/// Merge rules (each tested in DeskIdentityTests):
///  1. Every live window is included (source `.live`), with its desk identity and runtime identity.
///  2. A saved window is dropped when it corresponds to a live window, one-to-one, same app and any of: the same
///     document; the same exact title; the same browser page title; the same Chrome profile folder when the saved
///     layout has no more windows of that profile than the live record. The live record is newer and wins.
///  3. A saved window that corresponds (same rules) to a window that was on another display at the unplug is
///     dropped too: the user had it off the monitor then, so it stays where it is.
///  4. Other saved windows are kept (source `.saved`); one with an ID but no uuid takes the uuid of the live desk
///     with that ID. They never borrow a position from the live record by ordinal (0.6.11: the two records number
///     their desktops differently): the planner places one only when its own desktop is in the live strip, and
///     only for certain matches (document, title, browser title, title tie-break); a renamed one is never guessed.
///  5. With a frozen record and a snapshot: a saved window from rule 4 whose desk (by identity) is one of the
///     monitor's desks that the unplug moved to the built-in screen, and whose title changed, is paired with the
///     same app's unclaimed window on that desk when the counts are equal (source `.savedDeskEvidence`). Windows
///     on such a desk existed before the unplug (ID ≤ ceiling, app started before the freeze) and are on no list
///     are added as `.companion` windows of that desk: they were on the monitor at the unplug.
///     0.6.11: a window the record lists as elsewhere is never a companion (it was on another screen), and the
///     built-in screen's own desktops (`builtInDesks`) are never "moved by the unplug" (10/21 09:32:33).
public struct EffectiveLayout {
    public var record: MonitorLayoutRecord
    public var context: RestoreContext
    /// One line per decision, for the restore log (titles hashed).
    public var notes: [String]

    static func corresponds(_ saved: SavedWindow,_ selector: WindowSelector,profile: String?,profileOK: Bool) -> Bool {
        guard saved.selector.bundleID==selector.bundleID else { return false }
        if let d=saved.selector.document,!d.isEmpty,d==selector.document { return true }
        if !saved.selector.title.isEmpty,saved.selector.title==selector.title { return true }
        if BrowserTitles.isBrowser(saved.selector.bundleID) {
            let a=BrowserTitles.normalize(saved.selector.title)
            if !a.isEmpty,a==BrowserTitles.normalize(selector.title) { return true }
        }
        if profileOK,let f=saved.browserProfile,f==profile { return true }
        return false
    }

    public static func compose(saved: MonitorLayoutRecord?, live: LiveLayoutRecord?, monitor: MonitorIdentity, snapshot: Snapshot? = nil) -> EffectiveLayout? {
        guard let live else {
            guard let saved else { return nil }
            return EffectiveLayout(record:saved,context:RestoreContext(sources:saved.profile.windows.map{ _ in .saved },strip:DeskStrip(saved:saved)),notes:["layout: saved only (no live record)"])
        }
        var notes=["layout: live record \(live.windows.count) window(s) on \(live.desks.count) desk(s) recordedAt=\(RestoreLog.stamp.string(from:live.recordedAt))"+(live.frozenAt.map{" frozenAt=\(RestoreLog.stamp.string(from:$0))"} ?? " (not frozen)")+(live.windowIDCeiling.map{" ceiling=\($0)"} ?? "")]
        var windows=live.windows,sources=[WindowSource](repeating:.live,count:live.windows.count)
        let savedWindows=saved?.profile.windows ?? []
        // Rule 2 and 3, one-to-one, strongest correspondence first.
        var usedLive=Set<Int>(),usedElsewhere=Set<Int>(),dropped=Set<Int>()
        func profileCount(_ list: [SavedWindow],_ bundle: String,_ f: String) -> Int { list.filter{ $0.selector.bundleID==bundle && $0.browserProfile==f }.count }
        for pass in 0..<2 {
            for (i,s) in savedWindows.enumerated() where !dropped.contains(i) {
                let profileOK=pass==1 && s.browserProfile.map{ f in profileCount(savedWindows,s.selector.bundleID,f)<=profileCount(live.windows,s.selector.bundleID,f) } == true
                if let j=live.windows.indices.first(where:{ !usedLive.contains($0) && corresponds(s,live.windows[$0].selector,profile:live.windows[$0].browserProfile,profileOK:profileOK) }) {
                    usedLive.insert(j); dropped.insert(i)
                    notes.append("merge: saved #\(i) \(s.selector.bundleID) \(RestoreLog.hash(s.selector.title)) = live \(live.windows[j].runtime?.token ?? "-") (live wins)")
                    continue
                }
                let elsewhereProfileOK=pass==1 && s.browserProfile.map{ f in profileCount(savedWindows,s.selector.bundleID,f)<=live.elsewhere.filter{ $0.selector.bundleID==s.selector.bundleID && $0.browserProfile==f }.count } == true
                if let j=live.elsewhere.indices.first(where:{ !usedElsewhere.contains($0) && corresponds(s,live.elsewhere[$0].selector,profile:live.elsewhere[$0].browserProfile,profileOK:elsewhereProfileOK) }) {
                    usedElsewhere.insert(j); dropped.insert(i)
                    notes.append("merge: saved #\(i) \(s.selector.bundleID) \(RestoreLog.hash(s.selector.title)) was on another display at the unplug (\(live.elsewhere[j].runtime.token)); left where it is")
                }
            }
        }
        // Rule 4.
        for (i,var s) in savedWindows.enumerated() where !dropped.contains(i) {
            s.runtime=nil
            if let id=s.desktopID,s.desktopUUID == nil,let d=live.desks.first(where:{ $0.id==id }) { s.desktopUUID=d.uuid }
            windows.append(s); sources.append(.saved)
            notes.append("merge: saved #\(i) \(s.selector.bundleID) \(RestoreLog.hash(s.selector.title)) kept as saved-only (desk \(s.desktopID.map(String.init) ?? "-") ordinal \(s.desktopIndex.map(String.init) ?? "-"))")
        }
        // Rule 5.
        if let snapshot,let frozenAt=live.frozenAt {
            let builtIn=Set(snapshot.displays.filter{ $0.role == .builtIn }.map(\.token))
            let own=live.builtInDesks ?? []
            let migrated=snapshot.spaces.filter{ sp in sp.kind == .ordinary && builtIn.contains(sp.displayToken) && live.desks.contains{ $0.matches(sp) } && !own.contains{ $0.matches(sp) } }
            let elsewhere=Set(live.elsewhere.map(\.runtime.token))
            let claimed=Set(snapshot.windows.filter{ w in windows.contains{ $0.runtime?.matches(w)==true } || elsewhere.contains(w.token) }.map(\.token))
            func predates(_ w: ObservedWindow) -> Bool {
                guard let id=RuntimeWindowIdentity(token:w.token,processStartedAt:nil).windowID else { return false }
                if let c=live.windowIDCeiling,id>c { return false }
                if let started=w.processStartedAt,started>frozenAt { return false }
                return live.windowIDCeiling != nil
            }
            for sp in migrated {
                guard let desk=live.desks.first(where:{ $0.matches(sp) }) else { continue }
                let onDesk=snapshot.windows.filter{ WindowMatcher.eligible($0,snapshot) && $0.spaceIDs==[sp.id] && !claimed.contains($0.token) && predates($0) }
                for bundle in Set(onDesk.map(\.selector.bundleID)).sorted() {
                    var free=onDesk.filter{ $0.selector.bundleID==bundle }
                    // Saved-only windows of this app on this desk that nothing open strongly matches (renamed).
                    let open=windows.indices.filter{ i in sources[i] == .saved && windows[i].selector.bundleID==bundle && windows[i].desk.map{ $0.id==desk.id || ($0.uuid != nil && $0.uuid==desk.uuid) }==true
                        && !snapshot.windows.contains{ WindowMatcher.strong(windows[i],$0) != nil } }
                    if !open.isEmpty,open.count==free.count {
                        for i in open {
                            let pick=free.first{ WindowMatcher.geometryMatches(windows[i],$0,snapshot) } ?? free.sorted{ $0.token<$1.token }[0]
                            free.removeAll{ $0.token==pick.token }
                            windows[i].runtime=RuntimeWindowIdentity(token:pick.token,processStartedAt:pick.processStartedAt); sources[i] = .savedDeskEvidence
                            notes.append("merge: saved #\(i) \(bundle) \(RestoreLog.hash(windows[i].selector.title)) renamed → \(pick.token) \(RestoreLog.hash(pick.selector.title)): still on its desk \(desk.id), which the unplug moved to the built-in screen")
                        }
                    } else if !open.isEmpty {
                        notes.append("merge: \(open.count) saved-only \(bundle) window(s) on desk \(desk.id) vs \(free.count) unlisted window(s) there: not paired")
                    }
                    for w in free {
                        guard let display=snapshot.displays.first(where:{ $0.token==sp.displayToken }),display.visible.valid else { continue }
                        var c=SavedWindow(selector:w.selector,displayRole:.external,desktopLabel:"desk-\(desk.id)",normalizedFrame:w.frame.normalized(in:display.visible),
                                          desktopIndex:live.desks.firstIndex(of:desk).map{ $0+1 },desktopID:desk.id,desktopUUID:desk.uuid)
                        c.runtime=RuntimeWindowIdentity(token:w.token,processStartedAt:w.processStartedAt)
                        guard c.normalizedFrame.valid else { continue }
                        windows.append(c); sources.append(.companion)
                        notes.append("merge: companion \(w.token) \(bundle) \(RestoreLog.hash(w.selector.title)) on desk \(desk.id): existed before the unplug, not in any record")
                    }
                }
            }
        }
        var record=MonitorLayoutRecord(monitor:monitor,savedAt:live.frozenAt ?? live.recordedAt,profile:Profile(location:saved?.profile.location ?? monitor.name,windows:windows))
        record.coverage=saved?.coverage
        notes.append("layout: effective \(windows.count) window(s): live=\(sources.filter{ $0 == .live }.count) saved=\(sources.filter{ $0 == .saved }.count) deskEvidence=\(sources.filter{ $0 == .savedDeskEvidence }.count) companion=\(sources.filter{ $0 == .companion }.count) dropped=\(dropped.count)")
        notes.append("strip: source=live \(live.frozenAt.map{ "frozenAt="+RestoreLog.stamp.string(from:$0) } ?? "recordedAt="+RestoreLog.stamp.string(from:live.recordedAt)) L=\(live.desks.count) \(DeskStrip(live:live).logText); saved layout windows only by their own desktop")
        return EffectiveLayout(record:record,context:RestoreContext(sources:sources,frozenDesks:live.frozen ? live.desks : [],strip:DeskStrip(live:live)),notes:notes)
    }
}

/// How a strip position got its desktop (0.6.11). `anchor`: its own desktop, in order; `position`: by order (the
/// desktop at its place); `none`: no desktop yet (one has to be added) or no position.
public enum DeskMapping: String, Codable { case anchor, position, none }

/// One strip position with restorable windows, for the log and the "missing desktops" report.
public struct DeskGroupDecision: Equatable {
    public var key: String
    public var ordinal: Int?
    public var desk: DeskRef?
    public var windows: Int
    public var slot: Int?
    public var mapping: DeskMapping
    public var note: String
}
