// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// Quick arrangements: 「外接屏在上方 / 右边 / 下方 / 左边」 for the MacBook screen plus one external monitor, picked in
// LayoutKeeper itself instead of dragging in System Settings. The result is an ordinary preset (same relations, same
// plan, same preview → 保留 path), built from the sizes connected now.
//
// "Edge" always means where the external monitor sits relative to the MacBook screen, whichever of the two is main.
// The main display never changes: if the external monitor is main, it stays at (0,0) and the MacBook screen is the
// one that moves (the whole pair is translated, as in `plan`).

extension ArrangementGeometry {
    /// The MacBook screen and the one external monitor connected now.
    public static func pair(_ live: [LiveDisplay]) -> Result<(builtIn: LiveDisplay,external: LiveDisplay),ArrangementIssue> {
        let all: [LiveDisplay]
        switch usable(live) { case .failure(let e): return .failure(e); case .success(let l): all=l }
        let b=all.filter(\.builtIn), e=all.filter{ !$0.builtIn }
        guard b.count==1,e.count==1 else { return .failure(.notPair) }
        return .success((b[0],e[0]))
    }

    /// Rects with the external monitor on `edge` of the MacBook screen, aligned by `anchor`; the main one at (0,0).
    public static func quickRects(builtIn b: LiveDisplay,external e: LiveDisplay,edge: ArrangementEdge,anchor: ArrangementAnchor) -> (builtIn: IntRect,external: IntRect) {
        var br=IntRect(x:0,y:0,width:b.width,height:b.height)
        var er=place(width:e.width,height:e.height,against:br,ArrangementRelation(parent:b.key,edge:edge,anchor:anchor,offset:0))
        if e.isMain { br.x-=er.x; br.y-=er.y; er.x=0; er.y=0 }
        return (br,er)
    }

    /// A preset for 「外接屏在 `edge`，`anchor`」 with the displays connected now. Not saved; apply it, or save it.
    public static func quickPreset(_ live: [LiveDisplay],edge: ArrangementEdge,anchor: ArrangementAnchor,id: String,name: String? = nil,at date: Date) -> Result<ArrangementPreset,ArrangementIssue> {
        let b: LiveDisplay, e: LiveDisplay
        switch pair(live) { case .failure(let x): return .failure(x); case .success(let p): (b,e)=(p.builtIn,p.external) }
        let (br,er)=quickRects(builtIn:b,external:e,edge:edge,anchor:anchor)
        var sb=b, se=e
        (sb.x,sb.y,se.x,se.y)=(br.x,br.y,er.x,er.y)
        guard case .success(var preset)=capture([sb,se],id:id,name:name ?? quickName(edge:edge,anchor:anchor),at:date) else { return .failure(.notAdjacent) }
        // Exactly aligned, so the chosen anchor holds with offset 0 from either side (start/end/center are symmetric):
        // keep it rather than the tie-break capture picks when both have the same length along the edge.
        if preset.displays.count==2,var r=preset.displays[1].relation { r.anchor=anchor; r.offset=0; preset.displays[1].relation=r }
        return .success(preset)
    }

    /// Where the external monitor sits now (any alignment), for the ✓ in the menu. nil: not built-in + one external,
    /// or not touching along an edge.
    public static func currentEdge(_ live: [LiveDisplay]) -> ArrangementEdge? {
        guard case .success(let p)=pair(live) else { return nil }
        return edge(of:p.external.rect,against:p.builtIn.rect)
    }
    /// The exact alignment now, if it is one of the three without an offset (equal lengths: center).
    public static func currentAnchor(_ live: [LiveDisplay]) -> ArrangementAnchor? {
        guard case .success(let p)=pair(live),let edge=edge(of:p.external.rect,against:p.builtIn.rect) else { return nil }
        let r=p.external.rect, b=p.builtIn.rect
        let same=edge.slidesVertically ? r.height==b.height : r.width==b.width
        if same { return (edge.slidesVertically ? r.y==b.y : r.x==b.x) ? .center : nil }
        let (a,offset)=anchor(of:r,against:b,edge:edge)
        return offset==0 ? a : nil
    }

    /// 「外接屏在上方」, or with a non-centred alignment 「外接屏在上方（靠左）」.
    public static func quickName(edge: ArrangementEdge,anchor: ArrangementAnchor = .center) -> String {
        let base: String
        switch edge {
        case .above: base=lk("外接屏在上方")
        case .right: base=lk("外接屏在右边")
        case .below: base=lk("外接屏在下方")
        case .left: base=lk("外接屏在左边")
        }
        return anchor == .center ? base : lk("%@（%@）", base, alignmentLabel(edge:edge,anchor:anchor))
    }
    /// Short edge label for a picker: 上 / 右 / 下 / 左.
    public static func edgeLabel(_ edge: ArrangementEdge) -> String {
        switch edge {
        case .above: return lk("上方")
        case .right: return lk("右边")
        case .below: return lk("下方")
        case .left: return lk("左边")
        }
    }
    /// Alignment worded for the edge: above/below 靠左/居中/靠右, beside 靠上/居中/靠下.
    public static func alignmentLabel(edge: ArrangementEdge,anchor: ArrangementAnchor) -> String {
        switch (anchor,edge.slidesVertically) {
        case (.center,_): return lk("居中")
        case (.start,false): return lk("靠左")
        case (.end,false): return lk("靠右")
        case (.start,true): return lk("靠上")
        case (.end,true): return lk("靠下")
        }
    }
    /// Menu / picker order.
    public static let quickEdges: [ArrangementEdge]=[.above,.right,.below,.left]
}
