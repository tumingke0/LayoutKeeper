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
    /// Chrome profile as shown in its window title: the text after the last " - Google Chrome - ". Guest and
    /// Incognito windows get the special values "#guest" / "#incognito" so they never match a normal profile.
    /// nil when the title carries no profile (single-profile setups, other browsers). Only Chrome is parsed for now.
    public static let incognito="#incognito", guest="#guest"
    private static let profileSuffixes=[" - Google Chrome - "," - Google Chrome Beta - "," - Google Chrome Canary - "," - Google Chrome Dev - "]
    public static func profile(_ raw: String,bundleID: String) -> String? {
        guard bundleID.hasPrefix("com.google.Chrome") else { return nil }
        let title=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        if let r=title.range(of:#"Google Chrome[^-—–]*[(（]\s*(Incognito|无痕模式|无痕|隐身)\s*[)）]"#,options:[.regularExpression,.caseInsensitive]),!r.isEmpty { return incognito }
        if let r=title.range(of:#"Google Chrome[^-—–]*[(（]\s*(Guest|访客)\s*[)）]"#,options:[.regularExpression,.caseInsensitive]),!r.isEmpty { return guest }
        var best: Range<String.Index>?
        for suffix in profileSuffixes { if let r=title.range(of:suffix,options:.backwards),best == nil || r.lowerBound>best!.lowerBound { best=r } }
        guard let range=best else { return nil }
        let name=title[range.upperBound...].trimmingCharacters(in:.whitespaces)
        return name.isEmpty ? nil : name
    }
    /// "页面标题（sam）" for choice rows; plain normalized title for windows without a profile.
    public static func choiceLabel(_ raw: String,bundleID: String) -> String {
        guard isBrowser(bundleID) else { return raw }
        let title=normalize(raw)
        guard let p=profile(raw,bundleID:bundleID) else { return title }
        let shown=p == incognito ? lk("无痕") : (p == guest ? lk("访客") : p)
        return title+lk("（%@）", shown)
    }
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
        // Chrome's memory notice ("内存用量高 - 834 MB - " / "High memory usage - 834 MB - ") is not part of the page title.
        while let range=title.range(of:#"\s*(-\s*)?(内存用量高|High memory usage)\s*-\s*[\d.,]+\s*[KMG]B\s*(-\s*)?"#,options:[.regularExpression,.caseInsensitive]) {
            title.replaceSubrange(range,with:range.lowerBound==title.startIndex || range.upperBound==title.endIndex ? "" : " - ")
        }
        if let range=title.range(of:#"\s+and \d+ more pages?$"#,options:.regularExpression) { title.removeSubrange(range) }
        if let range=title.range(of:#"\s*和另外 ?\d+ ?个页面$"#,options:.regularExpression) { title.removeSubrange(range) }
        return title.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

public enum MatchKind: String, Codable { case document, title, browserTitle, browserProfile, tieBreak, slotGeometry, userChoice, onlyWindow, elimination, none }

public struct WindowMatch {
    public enum Verdict: Equatable { case unique, needsConfirmation, missing }
    public var verdict: Verdict
    public var kind: MatchKind
    public var chosen: ObservedWindow?
    /// A normally manual-only kind that is still certain (the only open window of the saved Chrome user).
    public var certain=false
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
    /// `savedOfApp`: how many windows of this app the layout saved. When it is 1 and the app has exactly one window now,
    /// that window is taken even if its title changed (a renamed chat or editor window is still the same window).
    public static func match(_ saved: SavedWindow,displayToken: String,snapshot s: Snapshot,choice: String? = nil,savedOfApp: Int = 0,browserProfiles: [String:String] = [:],savedOfProfile: Int = 1) -> WindowMatch {
        var pool=s.windows.filter{$0.selector.bundleID==saved.selector.bundleID && eligible($0,s)}
        // Chrome profiles: never cross Guest/Incognito with normal windows; when the saved window had a profile and
        // some live windows show the same one, only those are considered (a tie-breaker, not proof of identity).
        if BrowserTitles.isBrowser(saved.selector.bundleID),choice == nil {
            let savedProfile=BrowserTitles.profile(saved.selector.title,bundleID:saved.selector.bundleID)
            let special: Set<String>=[BrowserTitles.incognito,BrowserTitles.guest]
            pool=pool.filter{ w in
                let p=BrowserTitles.profile(w.selector.title,bundleID:w.selector.bundleID)
                return special.contains(p ?? "")==special.contains(savedProfile ?? "")
            }
        }
        // The choice list keeps every window; matching below drops windows known to be another Chrome profile.
        let allPool=pool
        if choice == nil,let folder=saved.browserProfile {
            pool=pool.filter{ browserProfiles[$0.token].map{ $0==folder } ?? true }
        }
        // Same-profile windows, used to break ties and for the fallbacks below.
        var profilePool=pool
        // Stable profile folder first (two Google accounts can both be called "sam"), then the title's display name.
        if let folder=saved.browserProfile,pool.contains(where:{browserProfiles[$0.token] != nil}) {
            let same=pool.filter{browserProfiles[$0.token]==folder}
            if !same.isEmpty { profilePool=same }
        } else if BrowserTitles.isBrowser(saved.selector.bundleID),let savedProfile=BrowserTitles.profile(saved.selector.title,bundleID:saved.selector.bundleID) {
            let same=pool.filter{BrowserTitles.profile($0.selector.title,bundleID:$0.selector.bundleID)==savedProfile}
            if !same.isEmpty { profilePool=same }
        }
        if let choice {
            guard let picked=pool.first(where:{$0.token==choice}) else {
                return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:allPool,reason:lk("之前选择的窗口已不存在，请重新选择"))
            }
            return WindowMatch(verdict:.unique,kind:.userChoice,chosen:picked,candidates:allPool,reason:lk("你选择的窗口"))
        }
        // Chrome profile folder identifies the window: tabs and titles change all the time, the profile does not.
        // One live window of the saved profile (and one saved window of it) is certain, even across displays.
        if let folder=saved.browserProfile {
            let same=pool.filter{browserProfiles[$0.token]==folder}
            if same.count==1 && savedOfProfile<=1 {
                let kind=strong(saved,same[0]) ?? .browserProfile
                return WindowMatch(verdict:.unique,kind:kind,chosen:same[0],candidates:allPool,reason:kind == .browserProfile ? lk("标题已变化；按 Chrome 用户认出这个窗口") : "")
            }
            if same.count>1 || (same.count==1 && savedOfProfile>1) {
                let titled=same.filter{ strong(saved,$0) != nil }
                if titled.count==1 { return WindowMatch(verdict:.unique,kind:.tieBreak,chosen:titled[0],candidates:allPool,reason:lk("同一 Chrome 用户有多个窗口，按标题选中一个")) }
                var left=titled.isEmpty ? same : titled
                if let index=saved.desktopIndex { left=left.filter{slot(of:$0,displayToken:displayToken,in:s)==index} }
                left=left.filter{geometryMatches(saved,$0,s)}
                if left.count==1 && !titled.isEmpty { return WindowMatch(verdict:.unique,kind:.tieBreak,chosen:left[0],candidates:allPool,reason:lk("同一 Chrome 用户有多个窗口，按保存时的桌面和位置选中一个")) }
                if left.count==1 { return WindowMatch(verdict:.unique,kind:.slotGeometry,chosen:left[0],candidates:allPool,reason:lk("同一 Chrome 用户有多个窗口，按保存时的桌面和位置选中一个")) }
                return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:allPool,reason:lk("同一 Chrome 用户有 %@ 个窗口，无法确定是哪一个，请选择", "\(same.count)"))
            }
        }
        if pool.isEmpty && !allPool.isEmpty {
            return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:allPool,reason:lk("打开的 Chrome 窗口都属于其他 Chrome 用户，请选择或跳过"))
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
        if strongs.count==1 { return WindowMatch(verdict:.unique,kind:strongs[0].1,chosen:strongs[0].0,candidates:allPool,reason:"") }
        if strongs.count>1 {
            let sameProfile=strongs.map(\.0).filter{ w in profilePool.contains{$0.token==w.token} }
            if sameProfile.count==1 && profilePool.count<pool.count { return WindowMatch(verdict:.unique,kind:.tieBreak,chosen:sameProfile[0],candidates:allPool,reason:lk("同名窗口有多个，按 Chrome 用户选中一个")) }
            let left=narrowed(sameProfile.isEmpty ? strongs.map(\.0) : sameProfile)
            if left.count==1 { return WindowMatch(verdict:.unique,kind:.tieBreak,chosen:left[0],candidates:allPool,reason:lk("同名窗口有多个，按保存时的桌面和位置选中一个")) }
            return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:allPool,reason:lk("有 %@ 个同名窗口，无法确定是哪一个，请选择", "\(strongs.count)"))
        }
        // No title/document match.
        if BrowserTitles.isBrowser(saved.selector.bundleID),let index=saved.desktopIndex {
            let placed=profilePool.filter{slot(of:$0,displayToken:displayToken,in:s)==index && geometryMatches(saved,$0,s)}
            // Exactly one browser window sits on the saved desktop at the saved position: take it (manual restore only;
            // autoEligible excludes .slotGeometry, so automatic restore still needs a certain match).
            if placed.count==1 { return WindowMatch(verdict:.unique,kind:.slotGeometry,chosen:placed[0],candidates:allPool,reason:lk("标题已变化；同一桌面同一位置只有这一个浏览器窗口，按它恢复")) }
        }
        if pool.count==1 && savedOfApp==1 && !BrowserTitles.isBrowser(saved.selector.bundleID) && (saved.selector.document ?? "").isEmpty {
            return WindowMatch(verdict:.unique,kind:.onlyWindow,chosen:pool[0],candidates:allPool,reason:lk("标题已变化；这个应用只有这一个窗口，按它恢复"))
        }
        // Title changed but only one window of the saved Chrome user is open: the profile identifies it, so it is
        // certain (auto-eligible) when the saved layout has only this one window of that user.
        if BrowserTitles.isBrowser(saved.selector.bundleID),profilePool.count==1,profilePool.count<pool.count {
            var m=WindowMatch(verdict:.unique,kind:.slotGeometry,chosen:profilePool[0],candidates:allPool,reason:lk("标题已变化；这个 Chrome 用户只有这一个窗口，按它恢复"))
            // Certain only when the stable profile folder proves it (display names like "sam" can repeat).
            m.certain=savedOfProfile<=1 && saved.browserProfile != nil && browserProfiles[profilePool[0].token]==saved.browserProfile
            return m
        }
        return WindowMatch(verdict:.needsConfirmation,kind:.none,chosen:nil,candidates:allPool,reason:lk("标题已变化，找到 %@ 个同应用窗口，请选择或跳过", "\(pool.count)"))
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
    /// Set when a normally manual-only match (elimination / single Chrome-user window) is nevertheless certain:
    /// the last unmatched saved window paired with the last unmatched live window of the app. Auto mode may run it.
    public var autoCertain=false
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
    /// How each pinned ready item was matched in the preview, so the frozen re-plan keeps its auto eligibility
    /// (a pin from the preview is not a user choice).
    public var confirmedMatches: [Int:PinnedMatch] {
        Dictionary(uniqueKeysWithValues:items.compactMap{ item in item.state == .ready && item.chosenToken != nil ? (item.savedIndex,PinnedMatch(kind:item.matchKind,autoCertain:item.autoCertain)) : nil })
    }
}

public struct PinnedMatch: Equatable { public var kind: MatchKind; public var autoCertain: Bool
    public init(kind: MatchKind,autoCertain: Bool=false) { self.kind=kind; self.autoCertain=autoCertain }
}

public enum QuickRestorePlanner {
    public static let oldRecordReason=lk("旧版布局缺少桌面顺序，请先重新保存一次此屏布局")
    public static func plan(record: MonitorLayoutRecord, monitor: MonitorIdentity, displayToken: String, snapshot s: Snapshot,
                            choices: [Int:QuickChoice] = [:], allowCrossSpace: Bool, crossSpaceBlockReason: String = lk("当前系统版本未验证跨桌面移动"),
                            overflowToLast: Bool = false,browserProfiles: [String:String] = [:],pinnedMatches: [Int:PinnedMatch] = [:]) throws -> QuickRestorePlan {
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
            let m=WindowMatcher.match(saved,displayToken:displayToken,snapshot:s,choice:choiceToken,savedOfApp:record.profile.windows.filter{$0.selector.bundleID==saved.selector.bundleID}.count,browserProfiles:browserProfiles,savedOfProfile:saved.browserProfile.map{ f in record.profile.windows.filter{$0.selector.bundleID==saved.selector.bundleID && $0.browserProfile==f}.count } ?? 0)
            item.candidates=m.candidates.map{QuickCandidate(token:$0.token,title:$0.selector.title,slot:WindowMatcher.slot(of:$0,displayToken:displayToken,in:s),frame:$0.frame)}
            item.matchKind=m.kind; item.reason=m.reason; item.chosenToken=m.chosen?.token; item.autoCertain=m.certain
            // A pin carried over from the preview keeps the preview's match kind, unless a known Chrome profile now differs.
            if m.kind == .userChoice,let pin=pinnedMatches[index],pin.kind != .userChoice,let w=m.chosen {
                if let f=saved.browserProfile,let live=browserProfiles[w.token],live != f {
                    item.state = .needsConfirmation; item.chosenToken=nil; item.reason=lk("窗口已属于其他 Chrome 用户，请重新选择"); items.append(item); continue
                }
                item.matchKind=pin.kind; item.autoCertain=pin.autoCertain
            }
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
            if item.reason.isEmpty { item.reason=item.crossDisplay ? lk("从另一块屏幕移回") : "" }
            pinned[index]=m.kind == .userChoice || m.kind == .tieBreak || m.kind == .browserProfile || m.kind == .onlyWindow || s.windows.filter{w.selector.matches($0.selector)}.count != 1
            items.append(item)
        }
        // One live window can satisfy only one saved record.
        var claimed=items.filter{[.ready,.alreadyInPlace,.blocked].contains($0.state)}.compactMap(\.chosenToken)
        for i in items.indices where [.ready,.alreadyInPlace,.blocked].contains(items[i].state) {
            if let token=items[i].chosenToken,claimed.filter({$0==token}).count>1 {
                items[i].state = .needsConfirmation; items[i].reason=lk("多个保存记录对应到同一个窗口，请逐个选择")
            }
        }
        claimed=items.filter{[.ready,.alreadyInPlace,.blocked].contains($0.state)}.compactMap(\.chosenToken)
        // Leftover windows of the same app: after certain matches are taken, if N unmatched saved windows and N
        // unmatched live windows remain for that app, pair them (manual restore only — not certain enough for auto).
        // Typical cases: a renamed WorkBuddy, or a Chrome tab whose title/URL changed while the other Chrome matched.
        resolveByElimination(&items,record:record,choices:choices,displayToken:displayToken,snapshot:s,ordinary:ordinary,display:display,allowCrossSpace:allowCrossSpace,crossSpaceBlockReason:crossSpaceBlockReason,overflowToLast:overflowToLast,claimed:&claimed,pinned:&pinned,browserProfiles:browserProfiles)
        // Last window of an app: when every other saved window of the app is matched for certain and the app has as
        // many live windows as saved ones, the single remaining Chrome slot match is certain too (unless a known
        // profile folder contradicts it).
        let strongKinds: Set<MatchKind>=[.document,.title,.browserTitle,.browserProfile,.onlyWindow]
        for bundle in Set(items.map(\.bundleID)) {
            let mine=items.indices.filter{ items[$0].bundleID==bundle }
            let weak=mine.filter{ !(strongKinds.contains(items[$0].matchKind) && [.ready,.alreadyInPlace].contains(items[$0].state)) }
            guard mine.count>1,weak.count==1,let i=weak.first,items[i].state == .ready,items[i].matchKind == .slotGeometry,choices[items[i].savedIndex] == nil,
                  let token=items[i].chosenToken else { continue }
            let live=s.windows.filter{ $0.selector.bundleID==bundle && WindowMatcher.eligible($0,s) }
            guard live.count==mine.count else { continue }
            if let f=record.profile.windows[items[i].savedIndex].browserProfile,let lf=browserProfiles[token],lf != f { continue }
            items[i].autoCertain=true
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
    /// Windows that macOS parked on the other screen (it does this when the monitor is unplugged) come back too,
    /// but only when their identity is certain: same document, same title, or same browser page.
    public static func autoSubset(_ quick: QuickRestorePlan) -> RestorePlan {
        var plan=quick.plan
        plan.entries=zip(quick.plan.entries,quick.entrySavedIndex).filter{ _,index in
            guard let item=quick.items.first(where:{$0.savedIndex==index}) else { return false }
            return autoEligible(item)
        }.map(\.0)
        return plan
    }

    /// Pair leftover unmatched saved windows with leftover live windows of the same app when the counts match.
    static func resolveByElimination(_ items: inout [QuickRestoreItem],record: MonitorLayoutRecord,choices: [Int:QuickChoice],displayToken: String,snapshot s: Snapshot,ordinary: [Space],display: Display,allowCrossSpace: Bool,crossSpaceBlockReason: String,overflowToLast: Bool,claimed: inout [String],pinned: inout [Int:Bool],browserProfiles: [String:String] = [:]) {
        let bundles=Set(items.filter{$0.state == .needsConfirmation}.map(\.bundleID))
        for bundle in bundles {
            // Never override an explicit user choice, and never guess document windows (another file is another window).
            let open=items.indices.filter{ items[$0].bundleID==bundle && items[$0].state == .needsConfirmation && choices[items[$0].savedIndex] == nil
                && (record.profile.windows[items[$0].savedIndex].selector.document ?? "").isEmpty }
            // All unresolved records of this app must be eligible, otherwise counts would not mean a one-to-one pairing.
            guard open.count==items.filter({ $0.bundleID==bundle && $0.state == .needsConfirmation }).count else { continue }
            guard !open.isEmpty else { continue }
            // Live windows of this app that no certain match has claimed yet.
            let taken=Set(claimed)
            let leftover=s.windows.filter{ $0.selector.bundleID==bundle && WindowMatcher.eligible($0,s) && !taken.contains($0.token) }
            // A Chrome window known to be another profile is never paired by elimination.
            let mismatch=open.contains{ i in record.profile.windows[items[i].savedIndex].browserProfile.map{ f in leftover.contains{ browserProfiles[$0.token].map{ $0 != f } ?? false } } ?? false }
            if mismatch { continue }
            if leftover.count != open.count {
                // Counts differ: only take a leftover window when it is the single one on the saved desktop at the
                // saved position for exactly one open record. Anything else keeps asking.
                var used=Set<String>()
                for i in open {
                    let saved=record.profile.windows[items[i].savedIndex]
                    guard let slot=saved.desktopIndex,slot<=ordinary.count else { continue }
                    let placed=leftover.filter{ WindowMatcher.slot(of:$0,displayToken:displayToken,in:s)==slot && WindowMatcher.geometryMatches(saved,$0,s) }
                    guard placed.count==1,!used.contains(placed[0].token) else { continue }
                    let rivals=open.filter{ j in j != i && { let o=record.profile.windows[items[j].savedIndex]; return o.desktopIndex==slot && WindowMatcher.geometryMatches(o,placed[0],s) }() }
                    guard rivals.isEmpty else { continue }
                    let pick=placed[0]; used.insert(pick.token)
                    let targetSpace=ordinary[slot-1].id
                    let frame=saved.normalizedFrame.fitted(in:display.visible)
                    items[i].chosenToken=pick.token; items[i].currentTitle=pick.selector.title; items[i].currentSlot=slot
                    items[i].matchKind = .elimination; items[i].targetFrame=frame
                    items[i].moveSpace=pick.spaceIDs != [targetSpace]; items[i].resize = !pick.frame.near(frame); items[i].crossDisplay=false
                    claimed.append(pick.token)
                    if !items[i].resize { items[i].state = .alreadyInPlace; items[i].reason=lk("已在保存的桌面和位置"); continue }
                    items[i].state = .ready; items[i].reason=lk("标题已变化；同一桌面同一位置只有这一个窗口，按它恢复"); pinned[i]=true
                }
                continue
            }
            // Pair by saved desktop, then by geometry, then by stable token order so the pairing is deterministic.
            var free=leftover
            for i in open.sorted(by:{ (items[$0].targetSlot ?? 0)<(items[$1].targetSlot ?? 0) }) {
                let saved=record.profile.windows[items[i].savedIndex]
                let pick: ObservedWindow
                if free.count==1 { pick=free.removeFirst() }
                else if let slot=saved.desktopIndex,let same=free.first(where:{WindowMatcher.slot(of:$0,displayToken:displayToken,in:s)==slot}) {
                    pick=same; free.removeAll{$0.token==pick.token}
                } else if let geo=free.first(where:{WindowMatcher.geometryMatches(saved,$0,s)}) {
                    pick=geo; free.removeAll{$0.token==pick.token}
                } else {
                    free.sort{$0.token<$1.token}; pick=free.removeFirst()
                }
                guard let savedTarget=saved.desktopIndex else { continue }
                var target=savedTarget
                if savedTarget>ordinary.count {
                    guard overflowToLast,let last=SharedLayout.targetSlot(saved:savedTarget,available:ordinary.count) else { continue }
                    target=last; items[i].targetSlot=last; items[i].overflowFrom=savedTarget
                }
                let targetSpace=ordinary[target-1].id
                let frame=saved.normalizedFrame.fitted(in:display.visible)
                items[i].chosenToken=pick.token; items[i].currentTitle=pick.selector.title
                items[i].currentSlot=WindowMatcher.slot(of:pick,displayToken:displayToken,in:s)
                items[i].candidates=leftover.map{QuickCandidate(token:$0.token,title:$0.selector.title,slot:WindowMatcher.slot(of:$0,displayToken:displayToken,in:s),frame:$0.frame)}
                items[i].matchKind = .elimination; items[i].targetFrame=frame
                items[i].moveSpace=pick.spaceIDs != [targetSpace]; items[i].resize = !pick.frame.near(frame)
                items[i].crossDisplay=items[i].currentSlot==nil
                if !items[i].moveSpace && !items[i].resize { items[i].state = .alreadyInPlace; items[i].reason=lk("已在保存的桌面和位置"); claimed.append(pick.token); continue }
                if items[i].moveSpace && !allowCrossSpace { items[i].state = .blocked; items[i].reason=crossSpaceBlockReason; continue }
                if items[i].moveSpace,let why=MoveScope.problem(window:pick,targetSpace:targetSpace,targetDisplay:displayToken,snapshot:s) {
                    items[i].state = .blocked; items[i].reason=lk("无法跨桌面移动：%@", "\(why)"); continue
                }
                items[i].state = .ready
                // Every other window of this app is matched with certainty and exactly one saved and one live window are left.
                items[i].autoCertain = open.count==1 && leftover.count==1 && items.filter{ $0.bundleID==bundle }.count>1
                items[i].reason=lk("同应用还有 %@ 个未匹配窗口，按剩余数量一一对应", "\(leftover.count)")
                pinned[i]=true; claimed.append(pick.token)
            }
        }
    }

    public static func autoEligible(_ item: QuickRestoreItem) -> Bool {
        guard item.state == .ready,item.matchKind != .userChoice else { return false }
        if item.autoCertain && (item.matchKind == .elimination || item.matchKind == .slotGeometry) { return true }
        // Only confidently identified windows move on their own. Being on the other display is not a reason to hold
        // back: after a plug-in nearly every window is, and manual restore moves them the same way.
        return [.document,.title,.browserTitle,.browserProfile,.onlyWindow].contains(item.matchKind)
    }
    /// Automatic only. Per app: U = saved windows still needing confirmation, L = live windows of that app that no
    /// other saved window has claimed. When every window in L already sits on the desk and geometry of every saved
    /// window in U, any pairing is a no-op, so nothing needs asking:
    ///  - |L| ≥ |U|: all of U are already in place;
    ///  - |L| < |U|: |L| of them are in place and the other |U|-|L| saved windows have no live window — missing.
    /// Otherwise (some candidate is elsewhere) the items stay needsConfirmation. Manual keeps asking.
    public static func quietAlreadyInPlace(_ quick: QuickRestorePlan,record: MonitorLayoutRecord,snapshot s: Snapshot,displayToken: String) -> (plan: QuickRestorePlan,quieted: [Int],missing: [Int]) {
        var q=quick, quieted=[Int](), missing=[Int]()
        let claimed=Set(q.items.filter{ [.ready,.alreadyInPlace,.blocked].contains($0.state) }.compactMap(\.chosenToken))
        for bundle in Set(q.items.filter{ $0.state == .needsConfirmation }.map(\.bundleID)).sorted() {
            let u=q.items.indices.filter{ q.items[$0].bundleID==bundle && q.items[$0].state == .needsConfirmation && record.profile.windows.indices.contains(q.items[$0].savedIndex) }
            let l=s.windows.filter{ $0.selector.bundleID==bundle && WindowMatcher.eligible($0,s) && !claimed.contains($0.token) }
            guard !u.isEmpty,!l.isEmpty else { continue }
            let allInPlace=u.allSatisfy { i in
                let saved=record.profile.windows[q.items[i].savedIndex]
                guard let desk=saved.desktopIndex else { return false }
                return l.allSatisfy{ WindowMatcher.slot(of:$0,displayToken:displayToken,in:s)==desk && WindowMatcher.geometryMatches(saved,$0,s) }
            }
            guard allInPlace else { continue }
            for (n,i) in u.enumerated() {
                if n<l.count { q.items[i].state = .alreadyInPlace; q.items[i].reason=lk("已在保存的桌面和位置"); quieted.append(q.items[i].savedIndex) }
                else { q.items[i].state = .missing; q.items[i].reason=lk("这个应用现在的窗口比保存时少，这个窗口可能已经关闭"); missing.append(q.items[i].savedIndex) }
            }
        }
        return (q,quieted,missing)
    }
    /// What execution runs: the preview's own matches (identification happens once, at plan time), filtered to
    /// `autoEligible` when automatic, each bound to the same live window token in `fresh`. Windows that are gone are
    /// blocked; nothing is re-matched or re-filtered. Entries are token-pinned so changed titles do not fail identity.
    public static func executionPlan(_ preview: QuickRestorePlan,autoOnly: Bool,fresh: Snapshot) -> (plan: RestorePlan,savedIndex: [Int],gone: [Int]) {
        var entries=[PlanEntry](), indices=[Int](), gone=[Int]()
        for (entry,index) in zip(preview.plan.entries,preview.entrySavedIndex) {
            if autoOnly { guard let item=preview.items.first(where:{$0.savedIndex==index}),autoEligible(item) else { continue } }
            var e=entry
            if let token=e.window?.token {
                if let live=fresh.windows.first(where:{$0.token==token}) { e.window=live; e.tokenPinned=true }
                else if e.status == .ready { e.status = .blocked; e.reason=lk("窗口已关闭，没有移动"); gone.append(index) }
            }
            entries.append(e); indices.append(index)
        }
        return (RestorePlan(session:fresh.session,topology:fresh.topology,entries:entries),indices,gone)
    }
}
