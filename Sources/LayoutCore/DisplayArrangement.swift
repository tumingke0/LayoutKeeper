// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// 显示器排列预设 (display arrangement presets).
//
// macOS remembers one arrangement per set of monitors. A user who puts the same monitor beside the MacBook on some
// days and above it on others has to drag it in System Settings every time. A preset stores the arrangement as
// relations ("the DELL sits on the MacBook's right, bottom edges aligned"), not as raw coordinates, so it still makes
// sense after a resolution or scaling change.
//
// Geometry is CoreGraphics global display space: points, y grows downward, the main display (menu bar) is at (0,0).
// Everything here is pure; the CoreGraphics reads and writes are in MacAdapters.DisplayArrangementIO.
//
// Rules learned from other projects (displayplacer, Cavendish, DisplayAlign, BetterDisplay):
// - There is no "set main display" call: the main display is whichever sits at (0,0). Applying translates the whole
//   layout so the display that is main *now* stays at (0,0): the main display never changes.
// - Every display gets an origin in the one transaction; a display left out is moved by WindowServer "as close as
//   possible to its current location", which is arbitrary.
// - WindowServer removes gaps and overlaps on its own, so a target must already be gapless, overlap-free and
//   edge-connected (touching corners do not count), and the result is read back.
// - If the sizes did not change since the preset was saved, the saved origins are used exactly (re-solving them
//   would discard a deliberate offset); only a size change re-solves from the relations.

public enum ArrangementEdge: String, Codable, CaseIterable, Sendable {
    case right, above, left, below
    /// Along which axis the two displays slide against each other: y for left/right, x for above/below.
    var slidesVertically: Bool { self == .right || self == .left }
    var opposite: ArrangementEdge {
        switch self { case .right: return .left; case .left: return .right; case .above: return .below; case .below: return .above }
    }
}

/// Which points of the two touching edges line up: start = top edges (beside) / left edges (above or below),
/// end = bottom / right edges, center = centres. `offset` (points) is added on top of the anchor.
public enum ArrangementAnchor: String, Codable, CaseIterable, Sendable { case start, center, end }

public struct ArrangementRelation: Codable, Equatable, Sendable {
    /// Key of the display this one is placed against (always placed earlier in `ArrangementPreset.displays`).
    public var parent: String
    public var edge: ArrangementEdge
    public var anchor: ArrangementAnchor
    public var offset: Int
    public init(parent: String,edge: ArrangementEdge,anchor: ArrangementAnchor,offset: Int) { self.parent=parent; self.edge=edge; self.anchor=anchor; self.offset=offset }
}

public struct ArrangementDisplay: Codable, Equatable, Sendable {
    /// "builtin", or "monitor-<vendor>-<model>-<serial>" (the physical monitor key, never the shared-layout key).
    public var key: String
    /// Display UUID when saved. Matched first (WindowServer keys its own arrangements on it); the key is the fallback
    /// because the UUID can differ when the same monitor is plugged into another port.
    public var uuid: String?
    public var name: String
    public var builtIn: Bool
    /// Size (points) and origin when saved, origin relative to the display that was main then.
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int
    /// nil only for the first display (the one that was main when saved).
    public var relation: ArrangementRelation?
    public init(key: String,uuid: String?,name: String,builtIn: Bool,width: Int,height: Int,x: Int,y: Int,relation: ArrangementRelation?) {
        self.key=key; self.uuid=uuid; self.name=name; self.builtIn=builtIn; self.width=width; self.height=height; self.x=x; self.y=y; self.relation=relation
    }
    var rect: IntRect { IntRect(x:x,y:y,width:width,height:height) }
}

/// When a preset applies itself. Only `.manual` exists; the field reserves room for later rules (e.g. "when this
/// monitor is plugged into that port"), which will default to off. Unknown values decode as `.manual`.
public enum ArrangementTrigger: Codable, Equatable, Sendable {
    case manual
    public init(from decoder: Decoder) throws { self = .manual }
    public func encode(to encoder: Encoder) throws { var c=encoder.singleValueContainer(); try c.encode("manual") }
}

public struct ArrangementPreset: Codable, Equatable, Identifiable {
    public var schemaVersion=1
    public var id: String
    public var name: String
    public var createdAt: Date
    /// Spanning-tree order: the display that was main first, every other display after its parent.
    public var displays: [ArrangementDisplay]
    public var hotkey: Hotkey?
    public var trigger: ArrangementTrigger = .manual
    public init(id: String,name: String,createdAt: Date,displays: [ArrangementDisplay],hotkey: Hotkey? = nil) {
        self.id=id; self.name=name; self.createdAt=createdAt; self.displays=displays; self.hotkey=hotkey
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, id, name, createdAt, displays, hotkey, trigger }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try c.decodeIfPresent(Int.self,forKey:.schemaVersion) ?? 1
        id=try c.decode(String.self,forKey:.id); name=try c.decode(String.self,forKey:.name)
        createdAt=try c.decode(Date.self,forKey:.createdAt); displays=try c.decode([ArrangementDisplay].self,forKey:.displays)
        hotkey=try c.decodeIfPresent(Hotkey.self,forKey:.hotkey)
        trigger=(try? c.decodeIfPresent(ArrangementTrigger.self,forKey:.trigger)) ?? .manual
    }
}

/// One display as it is right now (CoreGraphics global space, points).
public struct LiveDisplay: Equatable, Sendable {
    public var id: UInt32
    public var key: String
    public var uuid: String
    public var name: String
    public var builtIn: Bool
    public var isMain: Bool
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var mirrored: Bool
    public var asleep: Bool
    public init(id: UInt32,key: String,uuid: String,name: String,builtIn: Bool,isMain: Bool,x: Int,y: Int,width: Int,height: Int,mirrored: Bool = false,asleep: Bool = false) {
        self.id=id; self.key=key; self.uuid=uuid; self.name=name; self.builtIn=builtIn; self.isMain=isMain; self.x=x; self.y=y; self.width=width; self.height=height; self.mirrored=mirrored; self.asleep=asleep
    }
    var rect: IntRect { IntRect(x:x,y:y,width:width,height:height) }
    public static func key(builtIn: Bool,vendor: UInt32,model: UInt32,serial: UInt32) -> String { builtIn ? "builtin" : "monitor-\(vendor)-\(model)-\(serial)" }
}

public struct IntRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int,y: Int,width: Int,height: Int) { self.x=x; self.y=y; self.width=width; self.height=height }
    var maxX: Int { x+width }
    var maxY: Int { y+height }
}

public struct ArrangementTarget: Equatable, Sendable {
    public var id: UInt32
    public var key: String
    public var x: Int
    public var y: Int
    public init(id: UInt32,key: String,x: Int,y: Int) { self.id=id; self.key=key; self.x=x; self.y=y }
}

public struct ArrangementPlan: Equatable, Sendable {
    /// One origin for every display, the current main display at (0,0).
    public var targets: [ArrangementTarget]
    /// The displays are already arranged like this: nothing to apply (no flicker).
    public var alreadyApplied: Bool
    /// Sizes changed since the preset was saved, so origins were re-solved from the relations.
    public var resolved: Bool
}

/// Why a preset can't be saved or applied right now. `message` is shown to the user.
public enum ArrangementIssue: Error, Equatable, Sendable {
    case singleDisplay
    case mirroring
    case asleep
    case builtInOff
    case missing([String])
    case extra([String])
    case ambiguous(String)
    case notAdjacent
    case noMain
    case overlap
    /// The quick 「外接屏在上方/右边/下方/左边」 options need the MacBook screen plus exactly one external monitor.
    case notPair
    public var message: String {
        switch self {
        case .singleDisplay: return lk("只接了一块屏幕，没有可排列的")
        case .mirroring: return lk("屏幕正在镜像，镜像时不改排列")
        case .asleep: return lk("有屏幕在睡眠，醒来后再试")
        case .builtInOff: return lk("MacBook 屏幕没亮（合盖时不改排列）")
        case .missing(let names): return lk("没接上：%@", "\(names.joined(separator:lk("、")))")
        case .extra(let names): return lk("多接了：%@", "\(names.joined(separator:lk("、")))")
        case .ambiguous(let name): return lk("有两块「%@」，分不清哪块是哪块", "\(name)")
        case .notAdjacent: return lk("有屏幕没有和其他屏幕挨着")
        case .noMain: return lk("读不到主屏幕")
        case .overlap: return lk("分辨率变了，按原来的关系排会重叠")
        case .notPair: return lk("只在 MacBook 屏幕加一块外接屏时可用")
        }
    }
    /// Short code for the restore log.
    public var code: String {
        switch self {
        case .singleDisplay: return "single-display"
        case .mirroring: return "mirroring"
        case .asleep: return "asleep"
        case .builtInOff: return "builtin-off"
        case .missing(let n): return "missing(\(n.count))"
        case .extra(let n): return "extra(\(n.count))"
        case .ambiguous: return "ambiguous"
        case .notAdjacent: return "not-adjacent"
        case .noMain: return "no-main"
        case .overlap: return "overlap-after-resize"
        case .notPair: return "not-builtin-plus-one"
        }
    }
}

public enum ArrangementGeometry {
    /// Re-solved displays keep at least this much shared edge (points) so the pointer can cross between them.
    public static let minimumSharedEdge=64

    static func usable(_ live: [LiveDisplay]) -> Result<[LiveDisplay],ArrangementIssue> {
        if live.contains(where:\.mirrored) { return .failure(.mirroring) }
        if live.contains(where:\.asleep) { return .failure(.asleep) }
        if live.count<2 { return .failure(.singleDisplay) }
        guard live.filter(\.isMain).count==1 else { return .failure(.noMain) }
        return .success(live)
    }

    // MARK: - Capture

    /// The current arrangement as a preset. Relations form a spanning tree from the main display; each display is
    /// attached to the earliest placed display it shares an edge with (the main display whenever it touches it).
    public static func capture(_ live: [LiveDisplay],id: String,name: String,at date: Date) -> Result<ArrangementPreset,ArrangementIssue> {
        let all: [LiveDisplay]
        switch usable(live) { case .failure(let e): return .failure(e); case .success(let l): all=l }
        let main=all.first(where:\.isMain)!
        // Two monitors of the same model without serial numbers share a key: tell them apart by UUID.
        let counts=Dictionary(all.map{ ($0.key,1) },uniquingKeysWith:+)
        if Set(all.map{ $0.uuid.uppercased() }).count != all.count { return .failure(.ambiguous(all.first{ d in all.filter{ $0.uuid.uppercased()==d.uuid.uppercased() }.count>1 }!.name)) }
        // Origins relative to the main display (macOS already keeps it at 0,0; normalise anyway).
        let rel=all.map { d -> LiveDisplay in var c=d; c.x-=main.x; c.y-=main.y; if counts[d.key]!>1 { c.key=d.key+"#"+d.uuid.uppercased() }; return c }
        var order=[rel.first(where:\.isMain)!]
        var rest=rel.filter{ !$0.isMain }.sorted{ ($0.builtIn ? 0 : 1, $0.key, $0.uuid) < ($1.builtIn ? 0 : 1, $1.key, $1.uuid) }
        var out=[ArrangementDisplay(key:order[0].key,uuid:order[0].uuid,name:order[0].name,builtIn:order[0].builtIn,width:order[0].width,height:order[0].height,x:0,y:0,relation:nil)]
        while !rest.isEmpty {
            var progressed=false
            for parent in order {
                guard let i=rest.firstIndex(where:{ edge(of:$0.rect,against:parent.rect) != nil }) else { continue }
                let child=rest.remove(at:i)
                let edge=edge(of:child.rect,against:parent.rect)!
                let (anchor,offset)=anchor(of:child.rect,against:parent.rect,edge:edge)
                out.append(ArrangementDisplay(key:child.key,uuid:child.uuid,name:child.name,builtIn:child.builtIn,width:child.width,height:child.height,x:child.x,y:child.y,
                                              relation:ArrangementRelation(parent:parent.key,edge:edge,anchor:anchor,offset:offset)))
                order.append(child); progressed=true; break
            }
            if !progressed { return .failure(.notAdjacent) }
        }
        return .success(ArrangementPreset(id:id,name:name,createdAt:date,displays:out))
    }

    /// Which edge of `parent` the display `r` touches with a shared segment of positive length (corners don't count).
    static func edge(of r: IntRect,against p: IntRect) -> ArrangementEdge? {
        let ySpan=min(r.maxY,p.maxY)-max(r.y,p.y), xSpan=min(r.maxX,p.maxX)-max(r.x,p.x)
        if r.x==p.maxX && ySpan>0 { return .right }
        if r.maxX==p.x && ySpan>0 { return .left }
        if r.maxY==p.y && xSpan>0 { return .above }
        if r.y==p.maxY && xSpan>0 { return .below }
        return nil
    }

    /// The anchor nearest to how `r` actually sits along the edge, and the remaining offset. Exact alignment gives
    /// offset 0; ties prefer start, then end, then center (equal sizes make all three the same).
    static func anchor(of r: IntRect,against p: IntRect,edge: ArrangementEdge) -> (ArrangementAnchor,Int) {
        let (pos,len,pPos,pLen)=edge.slidesVertically ? (r.y,r.height,p.y,p.height) : (r.x,r.width,p.x,p.width)
        let candidates: [(ArrangementAnchor,Int)]=[(.start,pos-pPos),(.end,(pos+len)-(pPos+pLen)),(.center,pos-centered(pPos,pLen,len))]
        return candidates.min{ abs($0.1)<abs($1.1) }!
    }
    /// Position that centres a span of `len` on a span (`pPos`, `pLen`); floor for odd differences.
    static func centered(_ pPos: Int,_ pLen: Int,_ len: Int) -> Int { pPos+Int((Double(pLen-len)/2).rounded(.down)) }

    // MARK: - Match

    /// Preset key → live display. UUID first, then the physical key when exactly one live display has it.
    public static func match(_ preset: ArrangementPreset,_ live: [LiveDisplay]) -> Result<[String:LiveDisplay],ArrangementIssue> {
        var map=[String:LiveDisplay](), used=Set<UInt32>(), missing=[ArrangementDisplay]()
        for d in preset.displays {
            if let u=d.uuid,let l=live.first(where:{ $0.uuid.caseInsensitiveCompare(u) == .orderedSame && !used.contains($0.id) }) { map[d.key]=l; used.insert(l.id); continue }
            // Fallback: the physical key ("#UUID" marks same-model twins, which only the UUID can tell apart).
            let base=String(d.key.split(separator:"#",maxSplits:1).first ?? Substring(d.key))
            let same=live.filter{ $0.key==base && !used.contains($0.id) }
            if same.count>1 { return .failure(.ambiguous(d.name)) }
            if let l=same.first { map[d.key]=l; used.insert(l.id) } else { missing.append(d) }
        }
        if !missing.isEmpty {
            if missing.contains(where:\.builtIn) && !live.contains(where:\.builtIn) && missing.count==1 { return .failure(.builtInOff) }
            return .failure(.missing(missing.map(\.name)))
        }
        let extra=live.filter{ !used.contains($0.id) }
        if !extra.isEmpty { return .failure(.extra(extra.map(\.name))) }
        return .success(map)
    }

    // MARK: - Plan

    /// Origins for every display so the preset's relations hold, with the current main display kept at (0,0).
    public static func plan(_ preset: ArrangementPreset,_ live: [LiveDisplay]) -> Result<ArrangementPlan,ArrangementIssue> {
        if live.contains(where:\.mirrored) { return .failure(.mirroring) }
        if live.contains(where:\.asleep) { return .failure(.asleep) }
        let map: [String:LiveDisplay]
        switch match(preset,live) { case .failure(let e): return .failure(e); case .success(let m): map=m }
        guard map.count>=2 else { return .failure(.singleDisplay) }
        let resized=preset.displays.contains{ d in map[d.key].map{ $0.width != d.width || $0.height != d.height } ?? true }
        var rects=[String:IntRect]()
        if !resized {
            for d in preset.displays { rects[d.key]=d.rect }
        } else {
            for d in preset.displays {
                let size=map[d.key]!
                guard let rel=d.relation else { rects[d.key]=IntRect(x:0,y:0,width:size.width,height:size.height); continue }
                guard let p=rects[rel.parent] else { return .failure(.notAdjacent) }
                rects[d.key]=place(width:size.width,height:size.height,against:p,rel)
            }
        }
        // Keep the display that is main now at (0,0).
        guard let mainKey=map.first(where:{ $0.value.isMain })?.key,let anchor=rects[mainKey] else { return .failure(.noMain) }
        for k in rects.keys { rects[k]!.x-=anchor.x; rects[k]!.y-=anchor.y }
        let ordered=preset.displays.map{ (key:$0.key,rect:rects[$0.key]!) }
        if !valid(ordered.map(\.rect)) { return .failure(resized ? .overlap : .notAdjacent) }
        let targets=ordered.map{ ArrangementTarget(id:map[$0.key]!.id,key:$0.key,x:$0.rect.x,y:$0.rect.y) }
        let applied=targets.allSatisfy{ t in live.first{ $0.id==t.id }.map{ $0.x==t.x && $0.y==t.y } ?? false }
        return .success(ArrangementPlan(targets:targets,alreadyApplied:applied,resolved:resized))
    }

    /// Rect of a display of the given size placed against `p` by `rel`, keeping at least `minimumSharedEdge` shared.
    static func place(width: Int,height: Int,against p: IntRect,_ rel: ArrangementRelation) -> IntRect {
        let vertical=rel.edge.slidesVertically
        let len=vertical ? height : width, pPos=vertical ? p.y : p.x, pLen=vertical ? p.height : p.width
        var pos: Int
        switch rel.anchor {
        case .start: pos=pPos+rel.offset
        case .end: pos=pPos+pLen-len+rel.offset
        case .center: pos=centered(pPos,pLen,len)+rel.offset
        }
        let keep=min(minimumSharedEdge,len,pLen)
        pos=min(max(pos,pPos-len+keep),pPos+pLen-keep)
        switch rel.edge {
        case .right: return IntRect(x:p.maxX,y:pos,width:width,height:height)
        case .left: return IntRect(x:p.x-width,y:pos,width:width,height:height)
        case .above: return IntRect(x:pos,y:p.y-height,width:width,height:height)
        case .below: return IntRect(x:pos,y:p.maxY,width:width,height:height)
        }
    }

    /// No positive-area overlap, every display edge-connected to the others, exactly one at (0,0), Int32 range.
    public static func valid(_ rects: [IntRect]) -> Bool {
        guard !rects.isEmpty,rects.filter({ $0.x==0 && $0.y==0 }).count==1 else { return false }
        let limit=Int(Int32.max)/2
        guard rects.allSatisfy({ abs($0.x)<limit && abs($0.y)<limit && $0.width>0 && $0.height>0 }) else { return false }
        for i in rects.indices { for j in rects.indices where j>i {
            let a=rects[i], b=rects[j]
            if min(a.maxX,b.maxX)>max(a.x,b.x) && min(a.maxY,b.maxY)>max(a.y,b.y) { return false }
        } }
        var reached: Set<Int>=[0], frontier=[0]
        while let i=frontier.popLast() {
            for j in rects.indices where !reached.contains(j) && (edge(of:rects[j],against:rects[i]) != nil) { reached.insert(j); frontier.append(j) }
        }
        return reached.count==rects.count
    }

    // MARK: - Status, description

    public enum Status: Equatable, Sendable {
        /// Can be applied; `active` = the displays are already arranged like this.
        case applicable(active: Bool)
        /// Made for these displays but blocked right now (mirroring, asleep, overlap after a resize…).
        case blocked(ArrangementIssue)
        /// Made for another set of displays.
        case otherDisplays(ArrangementIssue)
    }
    public static func status(_ preset: ArrangementPreset,_ live: [LiveDisplay]) -> Status {
        switch match(preset,live) {
        case .failure(let e):
            if case .builtInOff=e { return .blocked(e) }
            return .otherDisplays(e)
        case .success: break
        }
        switch plan(preset,live) {
        case .success(let p): return .applicable(active:p.alreadyApplied)
        case .failure(let e): return .blocked(e)
        }
    }

    /// Display name in sentences: the built-in screen is always 「MacBook 屏幕」.
    static func displayName(_ d: ArrangementDisplay) -> String { d.builtIn ? lk("MacBook 屏幕") : d.name }
    /// 「在 DELL 右边」 reads better than 「在 DELL右边」: a space after a Latin name that runs into Chinese text.
    static func cjkSpaced(_ name: String) -> String {
        guard !Localization.isEnglish,let last=name.unicodeScalars.last,last.isASCII,CharacterSet.alphanumerics.contains(last) else { return name }
        return name+" "
    }
    static func alignment(_ r: ArrangementRelation) -> String {
        let base: String
        switch (r.anchor,r.edge.slidesVertically) {
        case (.center,_): base=lk("居中")
        case (.start,true): base=lk("顶边对齐")
        case (.end,true): base=lk("底边对齐")
        case (.start,false): base=lk("左边对齐")
        case (.end,false): base=lk("右边对齐")
        }
        return r.offset==0 ? base : lk("%@，错开 %@ 点", "\(base)", "\(r.offset)")
    }
    /// 「DELL S2421HSX 在 MacBook 屏幕上方，居中」; several displays are joined with ；.
    public static func describe(_ preset: ArrangementPreset) -> String {
        let byKey=Dictionary(preset.displays.map{ ($0.key,$0) },uniquingKeysWith:{ a,_ in a })
        return preset.displays.compactMap { d -> String? in
            guard let r=d.relation,let p=byKey[r.parent] else { return nil }
            let a=displayName(d), b=cjkSpaced(displayName(p)), c=alignment(r)
            switch r.edge {
            case .right: return lk("%@ 在 %@右边，%@", a, b, c)
            case .above: return lk("%@ 在 %@上方，%@", a, b, c)
            case .left: return lk("%@ 在 %@左边，%@", a, b, c)
            case .below: return lk("%@ 在 %@下方，%@", a, b, c)
            }
        }.joined(separator:lk("；"))
    }
    /// Default name for a new (custom) preset. Never one of the quick option names 「外接屏在正上方」…: a preset is
    /// only saved when it differs from those. Built-in + one external: 「外接屏在上方（靠左）」, or 「…（自定义）」 with an offset.
    public static func suggestedName(_ preset: ArrangementPreset) -> String {
        let byKey=Dictionary(preset.displays.map{ ($0.key,$0) },uniquingKeysWith:{ a,_ in a })
        let placed=preset.displays.filter{ $0.relation != nil }
        if placed.count==1,let d=placed.first,var r=d.relation,let p=byKey[r.parent] {
            var who: String?=nil
            if p.builtIn && !d.builtIn { who=nil }
            else if d.builtIn && !p.builtIn { r.edge=r.edge.opposite; r.offset = -r.offset }   // say where the monitor is
            else { who=d.name }
            let side: String
            switch r.edge {
            case .right: side=who.map{ lk("%@ 在右边", $0) } ?? lk("外接屏在右边")
            case .above: side=who.map{ lk("%@ 在上方", $0) } ?? lk("外接屏在上方")
            case .left: side=who.map{ lk("%@ 在左边", $0) } ?? lk("外接屏在左边")
            case .below: side=who.map{ lk("%@ 在下方", $0) } ?? lk("外接屏在下方")
            }
            let detail=r.offset != 0 ? lk("自定义") : alignmentLabel(edge:r.edge,anchor:r.anchor)
            return lk("%@（%@）", side, detail)
        }
        return lk("%@ 块屏幕的排列", "\(preset.displays.count)")
    }
    /// Same displays in the same places (relative to each other): saving it again would only make a duplicate.
    public static func sameArrangement(_ a: ArrangementPreset,_ b: ArrangementPreset) -> Bool {
        func shape(_ p: ArrangementPreset) -> [String:IntRect] {
            guard let root=p.displays.first else { return [:] }
            return Dictionary(p.displays.map{ ($0.key,IntRect(x:$0.x-root.x,y:$0.y-root.y,width:$0.width,height:$0.height)) },uniquingKeysWith:{ a,_ in a })
        }
        let sa=shape(a), sb=shape(b)
        guard Set(sa.keys)==Set(sb.keys),let k=sa.keys.sorted().first,let ra=sa[k],let rb=sb[k] else { return false }
        // Compare relative to one shared display, so a preset saved with another main display still compares equal.
        return sa.allSatisfy{ key,r in
            guard let o=sb[key] else { return false }
            return r.width==o.width && r.height==o.height && r.x-ra.x==o.x-rb.x && r.y-ra.y==o.y-rb.y
        }
    }
}

/// LayoutKeeper's own arrangement change must not look like a plug-in, a wake or an unplug to the reconnect and
/// live-record logic. A change starts with `begin` when the preview is written and stays in progress for the whole
/// confirmation (macOS posts screen events seconds after a reconfiguration, e.g. one ~5 s later while 「保留这个排列？」
/// is still open); `end` is called only once 保留 or 还原 has been written, and `grace` seconds after that are still
/// covered. Only screen events whose display set is exactly the one being arranged are LayoutKeeper's own: a different
/// set (a real plug or unplug in the same moment) is never covered, so it is handled as usual.
public struct SelfArrangementGuard: Equatable, Sendable {
    public static let grace: TimeInterval=8
    public private(set) var displays: Set<UInt32>?
    public private(set) var until: Date?
    public private(set) var inProgress=false
    public private(set) var label=""
    public init() {}
    /// Starts (or continues, for 保留/还原 after a preview) a change of these displays.
    public mutating func begin(displays ids: Set<UInt32>,label l: String) { displays=ids; inProgress=true; until=nil; label=l }
    /// The change is finished (kept, reverted, refused or failed): covered for `grace` more seconds.
    public mutating func end(at now: Date) { guard inProgress else { return }; inProgress=false; until=now+Self.grace }
    public func covers(_ current: Set<UInt32>,at now: Date) -> Bool {
        guard let displays,current==displays else { return false }
        return inProgress || (until.map{ now<$0 } ?? false)
    }
}

extension HotkeyRegistrar {
    /// Per-preset hotkeys, registered after the action hotkeys. `taken` holds the action hotkeys already registered
    /// (key → title), so a preset can't steal one; two presets with the same key: the first keeps it.
    public static func registerPresets(_ presets: [(id: String,title: String,key: Hotkey?)],enabled: Bool,taken initial: [Hotkey:String],attempt: (String,Hotkey) -> Bool) -> [String:HotkeyStatus] {
        var result=[String:HotkeyStatus](), taken=initial
        for p in presets {
            guard enabled else { result[p.id] = .off; continue }
            guard let key=p.key else { result[p.id] = .unset; continue }
            if let why=validate(key) { result[p.id] = .invalid(why); continue }
            if let owner=taken[key] { result[p.id] = .conflict(lk("与「%@」重复", "\(owner)")); continue }
            if attempt(p.id,key) { result[p.id] = .active; taken[key]=p.title }
            else { result[p.id] = .conflict(lk("%@ 注册失败：可能已被系统或其他应用占用，请换一个", "\(key.display)")) }
        }
        return result
    }
}

extension ArrangementMenu {
    /// The submenu for the displays connected now. Hidden with a single display and no presets at all.
    public static func build(presets: [ArrangementPreset],live: [LiveDisplay],busy: String?,hotkeysEnabled: Bool) -> ArrangementMenu? {
        guard live.count>=2 || !presets.isEmpty else { return nil }
        var entries=[Entry](), other=0
        for p in presets {
            // Same as one of 「外接屏在正上方 / 正右方 / 正下方 / 正左方」: that option already covers it.
            if ArrangementGeometry.quickEquivalent(p,live) != nil { continue }
            let key=hotkeysEnabled ? p.hotkey : nil
            switch ArrangementGeometry.status(p,live) {
            case .applicable(let active): entries.append(Entry(id:p.id,name:p.name,active:active,hotkey:key))
            case .blocked(let e): entries.append(Entry(id:p.id,name:p.name,active:false,hotkey:key,blocked:e.message))
            case .otherDisplays: other+=1
            }
        }
        let saveBlock: String?
        switch ArrangementGeometry.capture(live,id:"",name:"",at:Date()) { case .success: saveBlock=nil; case .failure(let e): saveBlock=e.message }
        let quickBlock: String?
        switch ArrangementGeometry.pair(live) { case .success: quickBlock=nil; case .failure(let e): quickBlock=e.message }
        let now=ArrangementGeometry.currentEdge(live)
        // Only one display: nothing to arrange, so no quick options (saved presets are still counted).
        let quick=live.count<2 ? [] : ArrangementGeometry.quickEdges.map{ ArrangementMenu.Quick(edge:$0,active:$0==now) }
        return ArrangementMenu(quick:quick,quickBlock:quickBlock,entries:entries,otherCount:other,saveBlock:saveBlock,busy:busy)
    }
}
