// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import CryptoKit

/// Pure planning helpers for the GUI self-test. The self-test itself runs the production
/// capture / planner / restorer / controlled mover; nothing here touches windows.
public enum SelfTestPlanner {
    public static let preferredCrossSpaceBundle="com.google.Chrome"

    /// Window chosen for the cross-Space step, with its current Space and a different ordinary target Space.
    public struct CrossSpaceChoice: Equatable {
        public var window: ObservedWindow
        public var source: UInt64
        public var target: UInt64
        public init(window: ObservedWindow, source: UInt64, target: UInt64) { self.window=window; self.source=source; self.target=target }
    }
    public struct Selection: Equatable {
        public var sameSpace: ObservedWindow?
        public var sameSpaceSkip: String?
        public var crossSpace: CrossSpaceChoice?
        public var crossSpaceSkip: String?
        public init() {}
    }

    /// Windows on ordinary Spaces of the selected display that uniquely match one saved window of the record.
    public static func eligibleWindows(record: MonitorLayoutRecord, snapshot: Snapshot, displayToken: String) -> [ObservedWindow] {
        let ordinary=Set(snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}.map(\.id))
        return snapshot.windows.filter { w in
            guard w.ordinary, !w.minimized, !w.fullScreen, w.frame.valid, w.spaceIDs.count==1, ordinary.contains(w.spaceIDs[0]), w.selector.usable else { return false }
            let saved=record.profile.windows.filter{$0.selector.matches(w.selector)}
            let live=snapshot.windows.filter{w.selector.matches($0.selector)}
            return saved.count==1 && live.count==1
        }.sorted{$0.token<$1.token}
    }

    public static func select(record: MonitorLayoutRecord, snapshot: Snapshot, displayToken: String, crossSpaceAvailable: Bool, crossSpaceUnavailableReason: String = lk("跨桌面后端在此系统构建上不可用")) -> Selection {
        var result=Selection()
        let eligible=eligibleWindows(record:record,snapshot:snapshot,displayToken:displayToken)
        let spaces=snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}
        let active=Set(spaces.filter(\.active).map(\.id))
        // Same-Space: a window on the active ordinary Space, non-Chrome first (titles of browser windows change more often).
        let onActive=eligible.filter{active.contains($0.spaceIDs[0])}
        result.sameSpace=onActive.first{$0.selector.bundleID != preferredCrossSpaceBundle} ?? onActive.first
        if result.sameSpace==nil { result.sameSpaceSkip=lk("外接屏当前桌面上没有已采集、可唯一识别的普通窗口") }
        guard crossSpaceAvailable else { result.crossSpaceSkip=crossSpaceUnavailableReason; return result }
        guard spaces.count>=2 else { result.crossSpaceSkip=lk("外接屏只有一个普通桌面，无法测试跨桌面"); return result }
        // Cross-Space: needs a known process start time; prefer Chrome and Spaces that are not shown, so nothing visibly jumps.
        let movable=eligible.filter{$0.processStartedAt != nil && $0.token != result.sameSpace?.token}
        let ordered=movable.sorted { a,b in
            func rank(_ w: ObservedWindow) -> Int { (w.selector.bundleID==preferredCrossSpaceBundle ? 0 : 2)+(active.contains(w.spaceIDs[0]) ? 1 : 0) }
            return rank(a) != rank(b) ? rank(a)<rank(b) : a.token<b.token
        }
        for window in ordered {
            let source=window.spaceIDs[0]
            let targets=spaces.filter{$0.id != source}.sorted { a,b in (a.active ? 1 : 0) < (b.active ? 1 : 0) }
            if let target=targets.first { result.crossSpace=CrossSpaceChoice(window:window,source:source,target:target.id); break }
        }
        if result.crossSpace==nil { result.crossSpaceSkip=movable.isEmpty ? lk("没有可唯一识别且有进程启动时间的外接屏窗口") : lk("没有可用的目标普通桌面") }
        return result
    }

    /// Saved-group → current-Space bindings, derived from where each group's windows are now.
    /// A group is bound only if all its matched windows agree on one ordinary Space of the display; no guessing.
    public static func groupSpaces(record: MonitorLayoutRecord, snapshot: Snapshot, displayToken: String) -> [String:UInt64] {
        let ordinary=Set(snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}.map(\.id))
        var result=[String:UInt64]()
        for label in Set(record.profile.windows.map(\.desktopLabel)) {
            var found=Set<UInt64>()
            for saved in record.profile.windows where saved.desktopLabel==label {
                let live=snapshot.windows.filter{saved.selector.matches($0.selector)}
                if live.count==1, live[0].spaceIDs.count==1, ordinary.contains(live[0].spaceIDs[0]) { found.insert(live[0].spaceIDs[0]) }
            }
            if found.count==1 { result[label]=found.first }
        }
        let used=Dictionary(grouping:result.values,by:{$0}).filter{$0.value.count>1}.keys
        return result.filter{!used.contains($0.value)}
    }

    /// Small visible change kept inside the display: shrink by (120,90) where possible, then move by (+40,+40).
    /// Shrinking first matters for windows that fill the visible frame, whose origin otherwise cannot move.
    public static func nudged(_ frame: Rect, within visible: Rect) -> Rect {
        let width=min(max(frame.width-120,min(frame.width,200)),visible.width)
        let height=min(max(frame.height-90,min(frame.height,150)),visible.height)
        let x=min(max(frame.x+40,visible.x),visible.x+visible.width-width)
        let y=min(max(frame.y+40,visible.y),visible.y+visible.height-height)
        return Rect(x,y,width,height)
    }

    /// Keeps only the plan entry for `token`; every other entry is skipped so the run never writes other windows.
    public static func restrict(_ plan: RestorePlan, toToken token: String) -> RestorePlan {
        var copy=plan
        for i in copy.entries.indices where copy.entries[i].window?.token != token {
            if copy.entries[i].status == .ready || copy.entries[i].status == .blocked { copy.entries[i].status = .skipped; copy.entries[i].reason=lk("自检未选中此窗口") }
        }
        return copy
    }

    public static func titleHash(_ title: String) -> String {
        SHA256.hash(data:Data(title.utf8)).prefix(4).map{String(format:"%02x",$0)}.joined()
    }
}

public enum SelfTestStatus: String, Codable { case pass, fail, skip, notRun }

public struct SelfTestWindowRef: Codable, Equatable {
    public var bundleID: String
    public var token: String
    public var titleHash: String
    public var spaceID: UInt64?
    public var slot: Int?
    public init(window: ObservedWindow, slot: Int?) {
        bundleID=window.selector.bundleID; token=window.token; titleHash=SelfTestPlanner.titleHash(window.selector.title)
        spaceID=window.spaceIDs.count==1 ? window.spaceIDs[0] : nil; self.slot=slot
    }
}
public struct SelfTestReadback: Codable, Equatable {
    public var label: String
    public var frame: Rect?
    public var spaceIDs: [UInt64]?
    public var expectedFrame: Rect?
    public var expectedSpace: UInt64?
    public var matches: Bool
    public init(label: String, observed: ObservedWindow?, expectedFrame: Rect?, expectedSpace: UInt64?, tolerance: Double = 3) {
        self.label=label; frame=observed?.frame; spaceIDs=observed?.spaceIDs; self.expectedFrame=expectedFrame; self.expectedSpace=expectedSpace
        if let observed {
            let frameOK=expectedFrame.map{observed.frame.near($0,tolerance:tolerance)} ?? true
            let spaceOK=expectedSpace.map{observed.spaceIDs==[$0]} ?? true
            matches=frameOK && spaceOK
        } else { matches=false }
    }
}
public struct SelfTestStep: Codable, Equatable {
    public var name: String
    public var status: SelfTestStatus = .notRun
    public var startedAtMs=0
    public var durationMs=0
    public var detail=""
    public var windows: [SelfTestWindowRef]=[]
    public var readbacks: [SelfTestReadback]=[]
    /// Exact result / dispatch strings (never window titles).
    public var messages: [String]=[]
    public init(name: String) { self.name=name }
}
public struct SelfTestSlot: Codable, Equatable {
    public var slot: Int; public var spaceID: UInt64; public var active: Bool
    public var cgCandidates: Int; public var captured: Int
    public init(slot: Int, spaceID: UInt64, active: Bool, cgCandidates: Int, captured: Int) { self.slot=slot; self.spaceID=spaceID; self.active=active; self.cgCandidates=cgCandidates; self.captured=captured }
}
public struct SelfTestAppCounts: Codable, Equatable {
    public var bundleID: String
    public var captured: Int
    public var cgCandidates: Int
    public var notInAX: Int
    public var sources: [String:Int]
    public var remoteWanted: Int
    public var remoteResolved: Int
    public var unresolved: Int
    public init(bundleID: String, captured: Int, cgCandidates: Int, notInAX: Int, sources: [String:Int], remoteWanted: Int, remoteResolved: Int, unresolved: Int) {
        self.bundleID=bundleID; self.captured=captured; self.cgCandidates=cgCandidates; self.notInAX=notInAX; self.sources=sources; self.remoteWanted=remoteWanted; self.remoteResolved=remoteResolved; self.unresolved=unresolved
    }
}
public struct SelfTestCapture: Codable, Equatable {
    public var scanMs=0
    public var completeness=""
    public var summary=""
    public var savedWindowCount=0
    public var slots: [SelfTestSlot]=[]
    public var applications: [SelfTestAppCounts]=[]
    public var globalReasons: [String:Int]=[:]
    public var trace: [CaptureTraceEntry]=[]
    public init() {}
}
public struct SelfTestReport: Codable, Equatable {
    public var schemaVersion=1
    public var startedAt=Date()
    public var finishedAt: Date?
    public var appVersion=""
    public var appBuild=""
    public var macOSVersion=""
    public var macOSBuild=""
    public var accessibilityTrusted=false
    public var controlledBuildSupported=false
    public var crossSpaceStatus: String?
    public var externalDisplayToken: String?
    public var externalMonitorName: String?
    public var confirmed=false
    public var cancelled=false
    public var timedOut=false
    public var capture=SelfTestCapture()
    public var steps: [SelfTestStep]=[]
    public init() {}

    /// fail if any step failed; pass if at least one write step passed and none failed.
    public var overall: SelfTestStatus {
        if steps.contains(where:{$0.status == .fail}) { return .fail }
        if steps.contains(where:{$0.status == .pass}) { return .pass }
        return steps.allSatisfy{$0.status == .notRun} ? .notRun : .skip
    }
    public func json() -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? String(data:encoder.encode(self),encoding:.utf8)) ?? "{}"
    }
    public static func decode(_ data: Data) throws -> SelfTestReport {
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(SelfTestReport.self,from:data)
    }
    public var text: String {
        func f(_ r: Rect?) -> String { r.map{"(\(Int($0.x)),\(Int($0.y)) \(Int($0.width))×\(Int($0.height)))"} ?? "—" }
        let formatter=ISO8601DateFormatter(); formatter.timeZone=TimeZone.current
        var lines=[lk("LayoutKeeper 一键自检报告"),lk("总体：%@%@%@", "\(overall.rawValue)", "\(cancelled ? lk("（用户中止）") : "")", "\(timedOut ? lk("（超时）") : "")"),
                   lk("开始：%@  结束：%@", "\(formatter.string(from:startedAt))", "\(finishedAt.map{formatter.string(from:$0)} ?? "—")"),
                   lk("LayoutKeeper %@ (%@)  macOS %@ (%@)  辅助功能：%@  跨桌面能力：%@", "\(appVersion)", "\(appBuild)", "\(macOSVersion)", "\(macOSBuild)", "\(accessibilityTrusted)", "\(crossSpaceStatus ?? (controlledBuildSupported ? lk("可用") : lk("不可用")))"),
                   lk("外接屏：%@  已确认执行：%@", "\(externalMonitorName ?? "—")", "\(confirmed)"),"",
                   lk("采集：%@ ms，可保存 %@ 个；%@", "\(capture.scanMs)", "\(capture.savedWindowCount)", "\(capture.summary)")]
        for slot in capture.slots { lines.append(lk("  桌面 %@%@ space=%@：候选 %@，可保存 %@", "\(slot.slot)", "\(slot.active ? lk("（当前）") : "")", "\(slot.spaceID)", "\(slot.cgCandidates)", "\(slot.captured)")) }
        for app in capture.applications {
            let sources=app.sources.keys.sorted().map{"\($0)=\(app.sources[$0] ?? 0)"}.joined(separator:",")
            lines.append(lk("  %@：可保存 %@，候选 %@，未对应 %@，其他桌面找回 %@/%@，未知 %@；来源 %@", "\(app.bundleID)", "\(app.captured)", "\(app.cgCandidates)", "\(app.notInAX)", "\(app.remoteResolved)", "\(app.remoteWanted)", "\(app.unresolved)", "\(sources)"))
        }
        if !capture.globalReasons.isEmpty { lines.append(lk("  全局原因：%@", "\(capture.globalReasons.keys.sorted().map{"\($0)=\(capture.globalReasons[$0] ?? 0)"}.joined(separator:", "))")) }
        for step in steps {
            lines.append("");lines.append(lk("[%@] %@（%@ ms）%@", "\(step.status.rawValue)", "\(step.name)", "\(step.durationMs)", "\(step.detail)"))
            for w in step.windows { lines.append(lk("  窗口 %@ %@ 标题#%@ space=%@ 桌面%@", "\(w.bundleID)", "\(w.token)", "\(w.titleHash)", "\(w.spaceID.map(String.init) ?? "—")", "\(w.slot.map(String.init) ?? "—")")) }
            for r in step.readbacks { lines.append(lk("  %@ %@：实际 %@ space=%@；期望 %@ space=%@", "\(r.matches ? "✓" : "✗")", "\(r.label)", "\(f(r.frame))", "\(r.spaceIDs?.map(String.init).joined(separator:",") ?? "—")", "\(f(r.expectedFrame))", "\(r.expectedSpace.map(String.init) ?? "—")")) }
            for m in step.messages { lines.append("  · \(m)") }
        }
        return lines.joined(separator:"\n")
    }
}
