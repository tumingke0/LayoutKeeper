// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// 0.6.11 desk strip. The external monitor's ordinary desktops form an ordered strip of positions, occupied or empty.
// Restoring reproduces that strip: position i's windows go to the i-th desktop, empty positions stay empty and keep
// their place, two positions never share a desktop and nothing overflows onto another desktop.
//
// Why positions and not desk identity: macOS destroys the external's first desktop at every unplug and makes a new
// one at every plug (new ID; on the same monitor the uuid can survive), hands the other desktops back to the same
// monitor in an order that is usually but not always kept (10/17 12:06 partly, 10/20 21:36 reversed), and gives a
// different monitor none of them. Desk identity is evidence for which position a desktop is, used only where it is
// consistent with the order ("anchors"); the position wins whenever the two disagree.

extension DeskRef {
    /// Same desktop on both sides: uuid when both have one, otherwise the ID.
    public func same(_ other: DeskRef) -> Bool {
        if let uuid,let o=other.uuid { return uuid==o }
        return id==other.id
    }
    /// Stricter: the ID and (when both have one) the uuid agree. Used for windows of the other record, where a
    /// recycled first-desktop uuid (10/19 desk 440 and 10/20 desk 484 share one) must not count as the same desktop.
    public func strictlySame(_ other: DeskRef) -> Bool {
        guard id==other.id else { return false }
        if let uuid,let o=other.uuid { return uuid==o }
        return true
    }
}

/// One position of the strip.
public struct StripSlot: Codable, Equatable {
    /// The desktop at this position when the strip was recorded (nil for old ordinal-only layouts).
    public var desk: DeskRef?
    /// Whether a window was on it when the strip was recorded (also windows that were not restorable, e.g. a
    /// minimized one or one with a duplicate title: the desktop was not empty).
    public var occupied: Bool
    public init(desk: DeskRef?, occupied: Bool) { self.desk=desk; self.occupied=occupied }
}

public struct DeskStrip: Equatable {
    public enum Source: String, Equatable { case live, saved, legacy }
    public var slots: [StripSlot]
    public var source: Source
    /// When the strip was recorded (frozen/recorded for live, savedAt for saved).
    public var recordedAt: Date?
    public init(slots: [StripSlot], source: Source, recordedAt: Date? = nil) { self.slots=slots; self.source=source; self.recordedAt=recordedAt }
    public var count: Int { slots.count }

    /// The strip of a live record: its desks in order, occupied where a recorded window sat.
    public init(live r: LiveLayoutRecord) {
        let used=Set(r.windows.compactMap(\.desktopID))
        slots=r.desks.map{ StripSlot(desk:$0,occupied:used.contains($0.id)) }
        source = .live; recordedAt=r.frozenAt ?? r.recordedAt
    }
    /// The strip of a saved layout: its desk list when it has one (0.6.11), else positions 1…L from the window
    /// ordinals, L = the number of desktops at save time when known.
    public init(saved r: MonitorLayoutRecord) {
        let windows=r.profile.windows
        recordedAt=r.savedAt
        if let desks=r.desks,!desks.isEmpty {
            let used=Set(r.occupiedDesks ?? []).union(windows.compactMap(\.desktopID))
            var s=desks.map{ StripSlot(desk:$0,occupied:used.contains($0.id)) }
            // A window ordinal beyond the list (should not happen) still gets a position of its own.
            let top=windows.compactMap(\.desktopIndex).max() ?? 0
            while s.count<top { s.append(StripSlot(desk:nil,occupied:true)) }
            slots=s; source = .saved; return
        }
        let length=max(r.coverage?.ordinaryDesktopCount ?? 0,windows.compactMap(\.desktopIndex).max() ?? 0)
        slots=(0..<length).map{ i in
            let here=windows.filter{ $0.desktopIndex==i+1 }
            let ids=Set(here.compactMap(\.desktopID))
            let desk=ids.count==1 ? here.first{ $0.desktopID != nil }?.desk : nil
            return StripSlot(desk:desk,occupied:!here.isEmpty)
        }
        source = .legacy
    }
    /// 1-based position of `desk` (same desktop by uuid, else ID).
    public func position(of desk: DeskRef) -> Int? { slots.firstIndex{ $0.desk?.same(desk)==true }.map{ $0+1 } }
    /// 1-based position of `desk` when ID and uuid both agree (windows of the other record).
    public func strictPosition(of desk: DeskRef) -> Int? { slots.firstIndex{ $0.desk?.strictlySame(desk)==true }.map{ $0+1 } }
    /// "[1:473· 2:454· 3:458● …]" for the log.
    public var logText: String {
        "["+slots.enumerated().map{ "\($0.offset+1):\($0.element.desk.map{ String($0.id) } ?? "?")\($0.element.occupied ? "●" : "·")" }.joined(separator:" ")+"]"
    }
}

/// Where each strip position goes on the current external display.
public struct StripMapping: Equatable {
    public enum Kind: String, Equatable { case anchored, positional }
    public var kind: Kind
    /// Per position (index = position-1): 0-based index into the current desktops; ≥ current count means a desktop
    /// that has to be added at the end first; nil = the position is dropped (an empty desktop the user deleted).
    public var target: [Int?]
    /// Anchors used (0-based position, 0-based desktop), the pinned first desktop included.
    public var anchors: [(Int,Int)]
    /// Positions (1-based) whose own desktop is on this display but out of order; their windows are moved to the
    /// desktop at their position instead.
    public var conflicts: [Int]
    /// Positions (1-based) dropped because their (empty) desktop no longer exists.
    public var dropped: [Int]
    /// Desktops the strip needs on this display (its kept length, placed after any extra desktops in between).
    public var needed: Int
    public var appended: Int, holes: Int, moves: Int
    /// The plan that was not chosen and its cost, for the log.
    public var alternative: String
    public static func == (a: StripMapping, b: StripMapping) -> Bool {
        a.kind==b.kind && a.target==b.target && a.anchors.map{ [$0.0,$0.1] }==b.anchors.map{ [$0.0,$0.1] } && a.conflicts==b.conflicts && a.dropped==b.dropped && a.needed==b.needed
    }
    /// 1-based target slot for a 1-based position (may exceed the current count), nil when dropped or unknown.
    public func slot(forPosition p: Int) -> Int? {
        guard p>=1,p<=target.count,let t=target[p-1] else { return nil }
        return t+1
    }
}

/// Maps a strip onto the current ordinary desktops. Two candidate plans:
///  X anchored — desktops of the strip that are on this display in a consistent order (longest increasing chain,
///    the first position pinned to the first desktop) stay where they are; positions between two anchors go to the
///    desktops between them in order. A gap with too few desktops may only drop empty positions whose desktop no
///    longer exists anywhere (the user deleted it); otherwise X is impossible. After the last anchor, missing
///    desktops are appended.
///  Y positional — position i → desktop i, missing desktops appended (trailing deleted empty positions dropped).
/// The plan with fewer appended desktops, then fewer holes (extra desktops left empty inside the strip), then fewer
/// moved windows-groups wins; a tie goes to X.
public enum StripMapper {
    public static func map(_ strip: DeskStrip,current: [Space],exists: (DeskRef) -> Bool) -> StripMapping {
        let L=strip.count, n=current.count
        func droppable(_ i: Int) -> Bool {
            guard i>0,!strip.slots[i].occupied,let d=strip.slots[i].desk else { return false }
            return !exists(d)
        }
        // Identity pairs (one desktop per position and vice versa).
        var pairs=[(Int,Int)](), usedJ=Set<Int>()
        for i in 0..<L {
            guard let d=strip.slots[i].desk,let j=current.firstIndex(where:{ d.same(DeskRef($0)) }),!usedJ.contains(j) else { continue }
            pairs.append((i,j)); usedJ.insert(j)
        }
        // The first desktop is always the first position (macOS recreates it), unless identity says otherwise.
        if L>0,n>0,!pairs.contains(where:{ $0.0==0 || $0.1==0 }) { pairs.insert((0,0),at:0) }
        pairs.sort{ $0.0<$1.0 }
        // Longest chain increasing in both; prefer occupied positions, then position == desktop.
        func weight(_ p: (Int,Int)) -> Int { 1000+(strip.slots[p.0].occupied ? 10 : 0)+(p.0==p.1 ? 1 : 0) }
        var best=[Int](repeating:0,count:pairs.count), prev=[Int](repeating:-1,count:pairs.count)
        for a in pairs.indices {
            best[a]=weight(pairs[a])
            for b in 0..<a where pairs[b].0<pairs[a].0 && pairs[b].1<pairs[a].1 && best[b]+weight(pairs[a])>best[a] { best[a]=best[b]+weight(pairs[a]); prev[a]=b }
        }
        var chain=[(Int,Int)]()
        if var k=best.indices.max(by:{ best[$0]<best[$1] || (best[$0]==best[$1] && $0>$1) }) {
            while k>=0 { chain.insert(pairs[k],at:0); k=prev[k] }
        }
        func cost(_ t: [Int?]) -> (appended: Int,moves: Int) {
            let top=t.compactMap{ $0 }.max().map{ $0+1 } ?? 0
            var moves=0
            for (i,j) in pairs where strip.slots[i].occupied && t[i] != j { moves+=1 }
            return (max(0,top-n),moves)
        }
        // X: anchored.
        var x=[Int?](repeating:nil,count:L), holes=0, feasible=true, droppedX=[Int]()
        var lastI = -1, lastJ = -1
        for (ai,aj) in chain+[(L,Int.max)] {
            let r=Array((lastI+1)..<ai)
            let tail=ai==L
            let dEnd=tail ? n : aj
            var free=Array((lastJ+1)..<max(lastJ+1,dEnd))
            var keep=r
            if keep.count>free.count {
                var lack=keep.count-free.count
                for i in keep.reversed() where lack>0 && droppable(i) { keep.removeAll{ $0==i }; droppedX.append(i+1); lack-=1 }
                if lack>0 && !tail { feasible=false }
            } else if !tail { holes+=free.count-keep.count }
            var next=free.isEmpty ? max(lastJ+1,tail ? n : aj) : free.last!+1
            for i in keep {
                if !free.isEmpty { x[i]=free.removeFirst() } else { x[i]=next; next+=1 }
            }
            if !tail { x[ai]=aj }
            lastI=ai; lastJ=tail ? lastJ : aj
        }
        // Y: positional.
        var y=(0..<L).map{ Optional($0) }, droppedY=[Int]()
        var i=L-1
        while i>=n && i>=0 && droppable(i) { y[i]=nil; droppedY.append(i+1); i-=1 }
        let cy=cost(y)
        let cx: (appended: Int,moves: Int) = feasible ? cost(x) : (Int.max,Int.max)
        let useX=feasible && (cx.appended,holes,cx.moves) <= (cy.appended,0,cy.moves)
        let t=useX ? x : y
        let c=useX ? cx : cy
        let conflicts=pairs.filter{ strip.slots[$0.0].occupied && t[$0.0] != $0.1 }.map{ $0.0+1 }
        let alt=useX ? "positional(append=\(cy.appended) holes=0 moves=\(cy.moves))"
                     : (feasible ? "anchored(append=\(cx.appended) holes=\(holes) moves=\(cx.moves))" : "anchored impossible (a deleted desktop held windows)")
        let top=t.compactMap{ $0 }.max().map{ $0+1 } ?? 0
        return StripMapping(kind:useX ? .anchored : .positional,target:t,anchors:useX ? chain : [],conflicts:conflicts,
                            dropped:(useX ? droppedX : droppedY).sorted(),needed:top,
                            appended:c.appended,holes:useX ? holes : 0,moves:c.moves,alternative:alt)
    }
}
