// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// One-click restore for the simple mode: derive desktop bindings by order, match windows
// conservatively, and produce a preview whose ready items feed the journaled ManualRestorer.

/// Browser window titles change with the active tab, so browsers are matched by a normalized title
/// plus the saved desktop slot and geometry. URLs are never the primary key.
public enum BrowserTitles {
    public static let bundles: Set<String>=[
        "com.google.Chrome","com.google.Chrome.beta","com.google.Chrome.canary","com.google.Chrome.dev","org.chromium.Chromium",
        "com.apple.Safari","com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac","com.microsoft.edgemac.Beta","com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser","org.mozilla.firefox","org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser","com.vivaldi.Vivaldi","com.operasoftware.Opera"
    ]
    private static let appNames=["Google Chrome","Chromium","Microsoft Edge","Safari","Arc","Mozilla Firefox","Firefox","Firefox Developer Edition","Brave","Vivaldi","Opera"]
    private static let separators=[" - "," — "," – "]
    public static func isBrowser(_ bundleID: String) -> Bool { bundles.contains(bundleID) }
    /// Strips a leading unread counter like "(3) " and an app-name suffix like " - Google Chrome" (and anything after it, e.g. a profile name).
    public static func normalize(_ raw: String) -> String {
        var title=raw.replacingOccurrences(of:"\u{200B}",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        if let range=title.range(of:#"^\(\d+\+?\)\s*"#,options:.regularExpression) { title.removeSubrange(range) }
        var cut=title.endIndex
        for separator in separators {
            for name in appNames {
                if let range=title.range(of:separator+name), range.lowerBound<cut {
                    let rest=title[range.upperBound...]
                    if rest.isEmpty || rest.hasPrefix(" ") { cut=range.lowerBound }
                }
            }
        }
        title=String(title[..<cut])
        if let range=title.range(of:#"\s+and \d+ more pages?$"#,options:.regularExpression) { title.removeSubrange(range) }
        if let range=title.range(of:#"\s*和另外 ?\d+ ?个页面$"#,options:.regularExpression) { title.removeSubrange(range) }
        return title.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

public enum MatchKind: String, Codable { case document, title, browserTitle, tieBreak, slotGeometry, userChoice, none }

public struct WindowMatch {
    public enum Verdict: Equatable { case unique, needsConfirmation, missing }
    public var verdict: Verdict
    public var kind: MatchKind
    public var chosen: ObservedWindow?
    /// Eligible same-app windows the user may pick from (always includes `chosen` when set).
    public var candidates: [ObservedWindow]
    public var reason: String
}

public enum WindowMatcher {
    public static let geometryTolerance=0.03
    static func eligible(_ w: ObservedWindow,_ s: Snapshot) -> Bool {
        w.ordinary && !w.minimized && !w.fullScreen && w.frame.valid && w.spaceIDs.count==1 &&
        s.spaces.contains{$0.id==w.spaceIDs[0] && $0.kind == .ordinary}
    }
    /// 1-based ordinary slot of the window on `displayToken`, nil when it is elsewhere.
    public static func slot(of w: ObservedWindow,displayToken: String,in s: Snapshot) -> Int? {
        guard w.spaceIDs.count==1 else { return nil }
        let ordinary=s.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}
        return ordinary.firstIndex{$0.id==w.spaceIDs[0]}.map{$0+1}
    }
    static func geometryMatches(_ saved: SavedWindow,_ w: ObservedWindow,_ s: Snapshot) -> Bool {
        guard let space=s.spaces.first(where:{$0.id==w.spaceIDs.first}),let display=s.displays.first(where:{$0.token==space.displayToken}),display.visible.valid else { return false }
        return w.frame.normalized(in:display.visible).near(saved.normalizedFrame,tolerance:geometryTolerance)
    }
    static func strong(_ saved: SavedWindow,_ w: ObservedWindow) -> MatchKind? {
        let s=saved.selector
        if BrowserTitles.isBrowser(s.bundleID) {
            let a=BrowserTitles.normalize(s.title),b=BrowserTitles.normalize(w.selector.title)
            return !a.isEmpty && a==b ? .browserTitle : nil
        }
        if let doc=s.document,!doc.isEmpty { return w.selector.document==doc ? .document : nil }
        return !s.title.isEmpty && s.title==w.selector.title ? .title : nil
    }
    public static func match(_ saved: SavedWindow,displayToken: String,snapshot s: Snapshot,choice: String? = nil) -> WindowMatch {
        let pool=s.windows.filter{$0.selector.bundleID==saved.selector.bundleID && eligible($0,s)}
        if let choice {
            guard let picked=pool.first(where:{$0.token==choice}) else {
                return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:pool,reason:lk("之前选择的窗口已不存在，请重新选择"))
            }
            return WindowMatch(verdict:.unique,kind:.userChoice,chosen:picked,candidates:pool,reason:lk("你选择的窗口"))
        }
        guard !pool.isEmpty else { return WindowMatch(verdict:.missing,kind:.none,chosen:nil,candidates:[],reason:lk("没有找到这个应用的可恢复窗口（不会启动应用）")) }
        let strongs=pool.compactMap{w in strong(saved,w).map{(w,$0)}}
        func narrowed(_ list: [ObservedWindow]) -> [ObservedWindow] {
            var list=list
            if let index=saved.desktopIndex {
                let sameSlot=list.filter{slot(of:$0,displayToken:displayToken,in:s)==index}
                if !sameSlot.isEmpty { list=sameSlot }
            }
            let sameGeometry=list.filter{geometryMatches(saved,$0,s)}
            if !sameGeometry.isEmpty { list=sameGeometry }
            return list
        }
        if strongs.count==1 { return WindowMatch(verdict:.unique,kind:strongs[0].1,chosen:strongs[0].0,candidates:pool,reason:"") }
        if strongs.count>1 {
            let left=narrowed(strongs.map(\.0))
            if left.count==1 { return WindowMatch(verdict:.unique,kind:.tieBreak,chosen:left[0],candidates:pool,reason:lk("同名窗口有多个，按保存时的桌面和位置选中一个")) }
            return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:pool,reason:lk("有 %@ 个同名窗口，无法确定是哪一个，请选择", "\(strongs.count)"))
        }
        // No title/document match.
        if BrowserTitles.isBrowser(saved.selector.bundleID),let index=saved.desktopIndex {
            let placed=pool.filter{slot(of:$0,displayToken:displayToken,in:s)==index && geometryMatches(saved,$0,s)}
            if placed.count==1 { return WindowMatch(verdict:.needsConfirmation,kind:.slotGeometry,chosen:placed[0],candidates:pool,reason:lk("标题已变化；同一桌面同一位置有一个浏览器窗口，已预选，请确认")) }
        }
        return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:pool,reason:lk("标题已变化，找到 %@ 个同应用窗口，请选择或跳过", "\(pool.count)"))
    }
}

public enum QuickChoice: Equatable { case window(String), skip }
public enum QuickItemState: String, Codable { case ready, needsConfirmation, alreadyInPlace, blocked, missing, skippedByUser
    public var label: String {
        switch self {
        case .ready: return lk("将恢复")
        case .needsConfirmation: return lk("需要确认")
        case .alreadyInPlace: return lk("已在原位")
        case .blocked: return lk("无法恢复")
        case .missing: return lk("未找到")
        case .skippedByUser: return lk("已跳过")
        }
    }
}
public struct QuickCandidate: Equatable, Identifiable {
    public var id: String { token }
    public var token: String; public var title: String; public var slot: Int?; public var frame: Rect
}
public struct QuickRestoreItem: Equatable, Identifiable {
    public var id: Int { savedIndex }
    public var savedIndex: Int
    public var bundleID: String
    public var savedTitle: String
    public var currentTitle: String?
    public var currentSlot: Int?
    public var targetSlot: Int?
    public var chosenToken: String?
    public var candidates: [QuickCandidate]
    public var matchKind: MatchKind
    public var state: QuickItemState
    public var reason: String
    public var moveSpace=false
    public var resize=false
    /// The window currently sits on another display; the cross-display Space move is not self-test verified, so auto mode skips it.
    public var crossDisplay=false
    /// Shared mode: the saved Space ordinal when it doesn't exist now and the window goes to the last Space instead.
    public var overflowFrom: Int?
    public var targetFrame: Rect?
    public var actionText: String {
        switch state {
        case .ready:
            var parts=[String]()
            if crossDisplay { parts.append(lk("从另一块屏幕移回")) } else if moveSpace { parts.append(overflowFrom != nil ? lk("暂放到最后一个桌面 %@", "\(targetSlot ?? 0)") : lk("移到桌面 %@", "\(targetSlot ?? 0)")) }
            if resize { parts.append(lk("调整位置和大小")) }
            return parts.joined(separator:" + ")
        default: return state.label
        }
    }
}
public struct QuickRestorePlan {
    public var items: [QuickRestoreItem]
    /// Only the ready items, in item order, for ManualRestorer.
    public var plan: RestorePlan
    public var entrySavedIndex: [Int]
    public var desktopsNow: Int
    public var desktopsNeeded: Int
    /// Spaces to add with Mission Control's + so every window gets its own saved Space again.
    public var missingDesktops: Int { SharedLayout.missingDesktops(needed:desktopsNeeded,available:desktopsNow) }
    public var readyCount: Int { items.filter{$0.state == .ready}.count }
    public var summary: String {
        let c={(s: QuickItemState) in self.items.filter{$0.state==s}.count}
        var parts=[lk("将恢复 %@", "\(c(.ready))"),lk("已在原位 %@", "\(c(.alreadyInPlace))")]
        if c(.needsConfirmation)>0 { parts.append(lk("需要确认 %@", "\(c(.needsConfirmation))")) }
        if c(.blocked)>0 { parts.append(lk("无法恢复 %@", "\(c(.blocked))")) }
        if c(.missing)>0 { parts.append(lk("未找到 %@", "\(c(.missing))")) }
        if c(.skippedByUser)>0 { parts.append(lk("已跳过 %@", "\(c(.skippedByUser))")) }
        return parts.joined(separator:" · ")
    }
    /// Choices that freeze the preview: ready windows stay pinned to their previewed token; everything else is skipped.
    public var confirmedChoices: [Int:QuickChoice] {
        Dictionary(uniqueKeysWithValues:items.map{ item in (item.savedIndex,item.state == .ready && item.chosenToken != nil ? .window(item.chosenToken!) : .skip) })
    }
}

public enum QuickRestorePlanner {
    public static let oldRecordReason=lk("旧版布局缺少桌面顺序，请先重新保存一次此屏布局")
    public static func plan(record: MonitorLayoutRecord, monitor: MonitorIdentity, displayToken: String, snapshot s: Snapshot,
                            choices: [Int:QuickChoice] = [:], allowCrossSpace: Bool, crossSpaceBlockReason: String = lk("当前系统版本未验证跨桌面移动"),
                            overflowToLast: Bool = false) throws -> QuickRestorePlan {
        try record.validate()
        guard record.monitor.key==monitor.key,let display=s.displays.first(where:{$0.token==displayToken && $0.role == .external}),display.visible.valid else { throw LayoutError.unsupported }
        let ordinary=s.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}
        var items=[QuickRestoreItem](),entries=[PlanEntry](),pinned=[Int:Bool]()
        let needed=record.profile.windows.compactMap(\.desktopIndex).max() ?? 0
        for (index,saved) in record.profile.windows.enumerated() {
            var item=QuickRestoreItem(savedIndex:index,bundleID:saved.selector.bundleID,savedTitle:saved.selector.title,currentTitle:nil,currentSlot:nil,targetSlot:saved.desktopIndex,chosenToken:nil,candidates:[],matchKind:.none,state:.missing,reason:"")
            if choices[index] == .skip { item.state = .skippedByUser; item.reason=lk("本次不恢复此窗口"); items.append(item); continue }
            var choiceToken: String?
            if case .window(let token)? = choices[index] { choiceToken=token }
            let m=WindowMatcher.match(saved,displayToken:displayToken,snapshot:s,choice:choiceToken)
            item.candidates=m.candidates.map{QuickCandidate(token:$0.token,title:$0.selector.title,slot:WindowMatcher.slot(of:$0,displayToken:displayToken,in:s),frame:$0.frame)}
            item.matchKind=m.kind; item.reason=m.reason; item.chosenToken=m.chosen?.token
            if let w=m.chosen { item.currentTitle=w.selector.title; item.currentSlot=WindowMatcher.slot(of:w,displayToken:displayToken,in:s) }
            switch m.verdict {
            case .missing: item.state = .missing; items.append(item); continue
            case .needsConfirmation: item.state = .needsConfirmation; items.append(item); continue
            case .unique: break
            }
            let w=m.chosen!
            guard let savedTarget=saved.desktopIndex else { item.state = .blocked; item.reason=oldRecordReason; items.append(item); continue }
            var target=savedTarget
            if savedTarget>ordinary.count {
                guard overflowToLast,let last=SharedLayout.targetSlot(saved:savedTarget,available:ordinary.count) else {
                    item.state = .blocked; item.reason=lk("保存时在桌面 %@，现在这块屏只有 %@ 个桌面：请先在调度中心新建桌面", "\(savedTarget)", "\(ordinary.count)"); items.append(item); continue
                }
                target=last; item.targetSlot=last; item.overflowFrom=savedTarget
                item.reason=lk("保存时在桌面 %@，现在只有 %@ 个桌面，先放到最后一个桌面；补齐桌面后会自动再恢复", "\(savedTarget)", "\(ordinary.count)")
            }
            let targetSpace=ordinary[target-1].id
            let frame=saved.normalizedFrame.fitted(in:display.visible)
            item.targetFrame=frame
            item.moveSpace=w.spaceIDs != [targetSpace]
            item.resize = !w.frame.near(frame)
            item.crossDisplay=item.currentSlot==nil
            if !item.moveSpace && !item.resize { item.state = .alreadyInPlace; if item.overflowFrom == nil { item.reason=lk("已在保存的桌面和位置") }; items.append(item); continue }
            if item.moveSpace && !allowCrossSpace { item.state = .blocked; item.reason=crossSpaceBlockReason; items.append(item); continue }
            if item.moveSpace,let why=MoveScope.problem(window:w,targetSpace:targetSpace,targetDisplay:displayToken,snapshot:s) {
                item.state = .blocked; item.reason=lk("无法跨桌面移动：%@", "\(why)"); items.append(item); continue
            }
            item.state = .ready
            if item.reason.isEmpty { item.reason=item.crossDisplay ? lk("从另一块屏幕移回（自动模式不会执行这一类）") : "" }
            pinned[index]=m.kind == .userChoice || m.kind == .tieBreak || s.windows.filter{w.selector.matches($0.selector)}.count != 1
            items.append(item)
        }
        // One live window can satisfy only one saved record.
        let claimed=items.filter{[.ready,.alreadyInPlace,.blocked].contains($0.state)}.compactMap(\.chosenToken)
        for i in items.indices where [.ready,.alreadyInPlace,.blocked].contains(items[i].state) {
            if let token=items[i].chosenToken,claimed.filter({$0==token}).count>1 {
                items[i].state = .needsConfirmation; items[i].reason=lk("多个保存记录对应到同一个窗口，请逐个选择")
            }
        }
        var entrySaved=[Int]()
        for item in items where item.state == .ready {
            let saved=record.profile.windows[item.savedIndex]
            guard let w=s.windows.first(where:{$0.token==item.chosenToken}),let slot=item.targetSlot else { continue }
            var entry=PlanEntry(saved:saved,status:.ready,reason:item.actionText,window:w,targetSpace:ordinary[slot-1].id,targetDisplay:displayToken,targetFrame:item.targetFrame)
            entry.tokenPinned=pinned[item.savedIndex]==true ? true : nil
            entries.append(entry); entrySaved.append(item.savedIndex)
        }
        return QuickRestorePlan(items:items,plan:RestorePlan(session:s.session,topology:s.topology,entries:entries),entrySavedIndex:entrySaved,desktopsNow:ordinary.count,desktopsNeeded:needed)
    }
    /// Auto mode: execute only items that were matched without any user input and are not on an unverified path.
    public static func autoSubset(_ quick: QuickRestorePlan) -> RestorePlan {
        var plan=quick.plan
        plan.entries=zip(quick.plan.entries,quick.entrySavedIndex).filter{ _,index in
            guard let item=quick.items.first(where:{$0.savedIndex==index}) else { return false }
            return item.state == .ready && !item.crossDisplay && item.matchKind != .userChoice && item.matchKind != .slotGeometry
        }.map(\.0)
        return plan
    }
}
