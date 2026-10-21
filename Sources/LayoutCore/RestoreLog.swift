// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import CryptoKit

/// Local log of display events, reconnects and restores (Diagnostics → 恢复记录), so a failed restore can be explained later.
/// Stays on this Mac. Lines carry app bundle IDs, window numbers, frames, Space ids, counts and error codes only —
/// never window titles, URLs, documents or user names. Titles appear only as short hashes (`t:1a2b3c`) so the same
/// window can be followed across lines. Rotates at ~5 MB, keeping one old file (`restore-log.old.txt`).
public struct RestoreLog {
    public let url: URL
    public var maxBytes: Int
    public init(url: URL,maxBytes: Int = 5_000_000) { self.url=url; self.maxBytes=maxBytes }
    public var oldURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent+".old."+(url.pathExtension.isEmpty ? "txt" : url.pathExtension)) }
    public static let stamp: DateFormatter = {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.dateFormat="yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
    public static func line(_ message: String,at date: Date) -> String {
        stamp.string(from:date)+"  "+message.replacingOccurrences(of:"\n",with:" ")
    }
    public func append(_ message: String,now: Date = Date()) { append([message],now:now) }
    public func append(_ messages: [String],now: Date = Date()) {
        guard !messages.isEmpty else { return }
        let fm=FileManager.default
        try? fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data=Data(messages.map{ Self.line($0,at:now)+"\n" }.joined().utf8)
        let size=((try? fm.attributesOfItem(atPath:url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size>0 && size+data.count>maxBytes {
            try? fm.removeItem(at:oldURL)
            try? fm.moveItem(at:url,to:oldURL)
        }
        if let h=try? FileHandle(forWritingTo:url) {
            defer { try? h.close() }
            _=try? h.seekToEnd(); try? h.write(contentsOf:data)
        } else { try? data.write(to:url,options:.atomic) }
    }
    public func read() -> [String] {
        guard let text=try? String(contentsOf:url,encoding:.utf8) else { return [] }
        return text.split(separator:"\n",omittingEmptySubsequences:true).map(String.init)
    }
    public func tail(_ n: Int) -> [String] { Array(read().suffix(n)) }

    // MARK: - Privacy-safe formatting

    /// First 6 hex characters of SHA-256: enough to correlate the same title across lines, useless to read it back.
    public static func hash(_ s: String?) -> String {
        guard let s,!s.isEmpty else { return "-" }
        return SHA256.hash(data:Data(s.utf8)).prefix(3).map{ String(format:"%02x",$0) }.joined()
    }
    public static func t(_ title: String?) -> String { "t:"+hash(title) }
    public static func r(_ f: Rect?) -> String {
        guard let f else { return "-" }
        return "(\(Int(f.x.rounded())),\(Int(f.y.rounded())) \(Int(f.width.rounded()))x\(Int(f.height.rounded())))"
    }
    public static func nr(_ f: Rect) -> String { String(format:"(%.3f,%.3f %.3fx%.3f)",f.x,f.y,f.width,f.height) }
    /// Display tokens are UUIDs; log a short hash (stable per display) plus the role.
    public static func d(_ token: String?) -> String { "d:"+hash(token?.uppercased()) }
    /// Monitor keys contain vendor/model/serial numbers only (no names); the shared key is a constant.
    public static func key(_ k: String?) -> String { k ?? "-" }

    public static func header(event: String,appVersion: String,build: String,os: String) -> [String] {
        ["==================== \(event) ====================",
         "session app=\(appVersion) build=\(build) macOS=\(os)"]
    }

    /// Displays and their Spaces in order (1-based ordinary slots), active Space marked with *.
    public static func snapshotLines(_ s: Snapshot,label: String,includeWindows: Bool,bundles: Set<String>? = nil) -> [String] {
        var out=["\(label) displays=\(s.displays.count) spaces=\(s.spaces.count) windows=\(s.windows.count) topology=\(hash(s.topology))"]
        for disp in s.displays {
            let spaces=s.spaces.filter{ $0.displayToken==disp.token }
            var slot=0
            let list=spaces.map { sp -> String in
                var tag="\(sp.id)"
                if sp.kind == .ordinary { slot+=1; tag="\(slot):\(sp.id)" } else { tag="\(sp.kind.rawValue):\(sp.id)" }
                return sp.active ? tag+"*" : tag
            }.joined(separator:",")
            out.append("\(label)  display \(d(disp.token)) role=\(disp.role.rawValue) visible=\(r(disp.visible)) spaces=[\(list)]")
        }
        if includeWindows {
            for w in s.windows where bundles == nil || bundles!.contains(w.selector.bundleID) {
                out.append("\(label)  win \(w.token) \(w.selector.bundleID) \(t(w.selector.title)) \(window(w,in:s))")
            }
        }
        return out
    }
    /// "disp=d:xxxx slot=2 sp=123 frame=(..) flags" for one live window.
    public static func window(_ w: ObservedWindow,in s: Snapshot) -> String {
        let sp=s.spaces.first{ w.spaceIDs.count==1 && $0.id==w.spaceIDs[0] }
        var slotText="-"
        if let sp,sp.kind == .ordinary,let i=s.spaces.filter({ $0.displayToken==sp.displayToken && $0.kind == .ordinary }).firstIndex(where:{ $0.id==sp.id }) { slotText="\(i+1)" }
        var flags=[String]()
        if !w.ordinary { flags.append("nonOrdinary") }
        if w.minimized { flags.append("minimized") }
        if w.fullScreen { flags.append("fullScreen") }
        if w.spaceIDs.count != 1 { flags.append("spaces=\(w.spaceIDs)") }
        if let sp,sp.kind != .ordinary { flags.append("spaceKind=\(sp.kind.rawValue)") }
        return "disp=\(d(sp?.displayToken)) slot=\(slotText) sp=\(w.spaceIDs.map(String.init).joined(separator:"+")) frame=\(r(w.frame))"+(flags.isEmpty ? "" : " ["+flags.joined(separator:",")+"]")
    }

    /// Exact reason why a plan item may or may not run in automatic mode (mirrors QuickRestorePlanner.autoEligible).
    public static func autoReason(_ i: QuickRestoreItem) -> String {
        if QuickRestorePlanner.autoEligible(i) { return i.autoCertain ? "yes(certain \(i.matchKind.rawValue))" : "yes" }
        if i.state != .ready { return "no(state=\(i.state.rawValue))" }
        switch i.matchKind {
        case .userChoice, .slotGeometry, .elimination: return "no(matchKind=\(i.matchKind.rawValue) is manual-only)"
        case .tieBreak: return "no(matchKind=tieBreak is not a confident identification)"
        default: return "no(matchKind=\(i.matchKind.rawValue))"
        }
    }

    /// One line per saved window: saved slot, candidates with live position, chosen match, state and auto eligibility.
    public static func planDetail(trigger: String,plan: QuickRestorePlan,record: MonitorLayoutRecord,snapshot s: Snapshot,displayToken: String,browserProfiles: [String:String] = [:]) -> [String] {
        var out=[String]()
        for i in plan.items {
            let windows=plan.windows.isEmpty ? record.profile.windows : plan.windows
            guard windows.indices.contains(i.savedIndex) else { continue }
            let saved=windows[i.savedIndex]
            var parts=["plan-item \(trigger) #\(i.savedIndex) \(i.bundleID) \(t(saved.selector.title))"]
            if let doc=saved.selector.document,!doc.isEmpty { parts.append("doc:\(hash(doc))") }
            if let p=saved.browserProfile { parts.append("profile=\(p)") }
            if let tp=BrowserTitles.profile(saved.selector.title,bundleID:saved.selector.bundleID) { parts.append("titleProfile:\(hash(tp))") }
            parts.append("saved{role=\(saved.displayRole.rawValue) desk=\(saved.desktopIndex.map(String.init) ?? "-") deskID=\(saved.desktopID.map(String.init) ?? "-") nframe=\(nr(saved.normalizedFrame))}")
            parts.append("src=\(i.source.logName)"+(saved.runtime.map{ " rt=\($0.token)" } ?? "")+" group=\(groupTag(i.groupKey)) deskMap=\(i.deskMapping.rawValue)")
            parts.append("state=\(i.state.rawValue) match=\(i.matchKind.rawValue) chosen=\(i.chosenToken ?? "none")")
            parts.append("cur=\(i.currentSlot.map(String.init) ?? "-")→target=\(i.targetSlot.map(String.init) ?? "-")"+(i.targetSpaceID.map{" sp=\($0)"} ?? ""))
            parts.append("moveSpace=\(i.moveSpace) resize=\(i.resize) crossDisplay=\(i.crossDisplay) targetFrame=\(r(i.targetFrame))")
            parts.append("auto=\(autoReason(i))")
            if !i.reason.isEmpty { parts.append("reason=\"\(i.reason)\"") }
            if i.stale { parts.append("stale(others=\(i.staleOthers))") }
            out.append(parts.joined(separator:" "))
            let pool=s.windows.filter{ $0.selector.bundleID==i.bundleID }
            if pool.isEmpty { out.append("  cand none (no live window of \(i.bundleID))") }
            for w in pool {
                let strong=WindowMatcher.strong(saved,w).map(\.rawValue) ?? "-"
                let eligible=WindowMatcher.eligible(w,s)
                let geo=eligible && WindowMatcher.geometryMatches(saved,w,s)
                let slotNow=WindowMatcher.slot(of:w,displayToken:displayToken,in:s)
                var c="  cand \(w.token) \(t(w.selector.title)) \(window(w,in:s)) eligible=\(eligible) strong=\(strong) sameSlot=\(slotNow != nil && slotNow==saved.desktopIndex) geometry=\(geo)"
                if let p=browserProfiles[w.token] { c+=" profile=\(p)" }
                if let tp=BrowserTitles.profile(w.selector.title,bundleID:w.selector.bundleID) { c+=" titleProfile:\(hash(tp))" }
                if w.token==i.chosenToken { c+=" <= CHOSEN" }
                out.append(c)
            }
        }
        return out
    }

    /// Group keys hold desk uuids; log a short hash for uuid keys, IDs and labels as they are (labels are random).
    public static func groupTag(_ key: String) -> String { key.hasPrefix("u:") ? "u:"+hash(String(key.dropFirst(2))) : key }
    /// The desk strip of this restore and how it maps onto the display, then one line per position with windows.
    public static func deskMapLines(trigger: String,plan: QuickRestorePlan) -> [String] {
        var out=[String]()
        if let strip=plan.strip,let m=plan.mapping {
            out.append("strip: \(trigger) source=\(strip.source.rawValue)\(strip.recordedAt.map{ " at="+stamp.string(from:$0) } ?? "") L=\(strip.count) \(strip.logText)")
            out.append("strip: \(trigger) now [\(plan.desktopsNow) desktop(s)] plan=\(m.kind.rawValue) anchors=[\(m.anchors.map{ "\($0.0+1)→\($0.1+1)" }.joined(separator:","))] conflicts=[\(m.conflicts.map(String.init).joined(separator:","))] dropped=[\(m.dropped.map(String.init).joined(separator:","))] needed=\(m.needed) append=\(m.appended) holes=\(m.holes) moves=\(m.moves) (other: \(m.alternative))")
        }
        out+=plan.groups.map{ g in "strip: \(trigger) pos\(g.ordinal.map(String.init) ?? "-") desk=\(g.desk.map{ String($0.id) } ?? "-") windows=\(g.windows) → \(g.mapping.rawValue) slot=\(g.slot.map(String.init) ?? "-") (\(g.note))" }
        return out
    }
    /// Per executed window: before/after frames and Spaces, target, final journal state and detail (error text, AX codes).
    public static func journalLines(trigger: String,report: ManualRestoreReport) -> [String] {
        guard let j=report.journal else { return ["exec \(trigger) no journal (nothing written)"] }
        return j.entries.map { e in
            let b=e.before, a=e.after
            return "exec \(trigger) \(b.token) \(b.selector.bundleID) \(t(b.selector.title)) state=\(e.state.rawValue) before{sp=\(b.spaceIDs) frame=\(r(b.frame)) disp=\(d(e.sourceDisplay))} target{sp=\(e.targetSpace.map(String.init) ?? "-") frame=\(r(e.targetFrame)) disp=\(d(e.targetDisplay))} after{sp=\(a.map{"\($0.spaceIDs)"} ?? "-") frame=\(r(a?.frame))} spaceMoved=\(a.map{ e.targetSpace == nil || $0.spaceIDs==[e.targetSpace!] }.map(String.init) ?? "-") pinned=\(e.tokenPinned == true) detail=\"\(e.detail)\""
        }
    }

    /// One-line summary of a restore run for the log.
    public static func summary(trigger: String,report: ManualRestoreReport) -> String {
        let states=Dictionary(grouping:report.journal?.entries ?? [],by:\.state.rawValue).mapValues(\.count).sorted{$0.key<$1.key}.map{"\($0.key)=\($0.value)"}.joined(separator:",")
        let failed=report.failures.map{"\($0.bundleID):\($0.reason.rawValue)"}.joined(separator:",")
        return "restore \(trigger) windows=\(report.results.count) [\(states)]"+(failed.isEmpty ? "" : " failures=[\(failed)]")
    }

    /// One-line plan summary: per-item state/match for the restore planner, bundle IDs only (no titles).
    public static func planSummary(trigger: String,plan: QuickRestorePlan) -> String {
        let items=plan.items.map { i -> String in
            var tags=[i.state.rawValue,i.matchKind.rawValue]
            if i.crossDisplay { tags.append("crossDisplay") }
            if i.state == .ready { tags.append(QuickRestorePlanner.autoEligible(i) ? "auto" : "noAuto") }
            return "\(i.bundleID):"+tags.joined(separator:"/")
        }.joined(separator:",")
        return "plan \(trigger) ready=\(plan.readyCount) autoRunnable=\(QuickRestorePlanner.autoSubset(plan).entries.count) desktops=\(plan.desktopsNow)/\(plan.desktopsNeeded) [\(items)]"
    }
}
