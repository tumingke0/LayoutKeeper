// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public struct MonitorIdentity: Codable, Equatable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var name: String
    public init(vendor: UInt32, model: UInt32, serial: UInt32, name: String) { self.vendor=vendor; self.model=model; self.serial=serial; self.name=name }
    public var key: String { isSharedExternal ? Self.sharedExternalKey : "monitor-\(vendor)-\(model)-\(serial)" }
    public var identifiesDevice: Bool { vendor != 0 && model != 0 && serial != 0 }
}
public struct MonitorLayoutRecord: Codable {
    public var schemaVersion=1
    public var monitor: MonitorIdentity
    public var savedAt: Date
    public var profile: Profile
    public var coverage: ExternalCaptureCoverage?
    public var captureReport: CapturePipelineReport?
    public var completeness: CaptureCompleteness?
    public init(monitor: MonitorIdentity, savedAt: Date = Date(), profile: Profile) { self.monitor=monitor; self.savedAt=savedAt; self.profile=profile }
    public func validate() throws {
        guard schemaVersion==1,monitor.vendor != 0,monitor.model != 0,profile.windows.allSatisfy({$0.displayRole == .external}) else { throw LayoutError.invalidProfile }
        try profile.validate()
        if let captureReport {try captureReport.validate(capturedCount:profile.windows.count);guard completeness==captureReport.completeness else{throw LayoutError.invalidProfile}}
    }
    public var captureSummary:String {
        if let captureReport {return lk("保存当时的采集统计：")+captureReport.summary}
        let groups=coverage?.representedDesktopCount ?? Set(profile.windows.map(\.desktopLabel)).count
        let total=coverage?.ordinaryDesktopCount ?? groups
        return lk("已保存 %@ 个窗口，覆盖 %@/%@ 个普通桌面。完整性未确认；旧记录没有逐阶段统计。", "\(profile.windows.count)", "\(groups)", "\(total)")
    }
}
public struct ExternalCaptureCoverage: Codable, Equatable {
    public var scope="enumerable-windows-only; completeness not guaranteed"
    public var ordinaryDesktopCount: Int
    public var representedDesktopCount: Int
    public var readableWindowCount: Int
    public var excludedReadableWindowCount: Int? = nil
    public var readIssueCount: Int? = nil
}
public enum ExternalLayoutCapture {
    // Logical group labels are generated independently of observed Space IDs or desktop order.
    // They preserve grouping, but cannot resolve a desktop after reconnection without a validated backend.
    public static func capture(monitor: MonitorIdentity, displayToken: String, snapshot: Snapshot,report measurement:CapturePipelineReport?=nil) throws -> (MonitorLayoutRecord,[String]) {
        let result=try assess(monitor:monitor,displayToken:displayToken,snapshot:snapshot,report:measurement)
        return (result.record,result.issues)
    }
    /// Same as `capture`, plus a runtime-only decision per observed window token
    /// ("captured" or a CaptureReason raw value). Decisions are never stored in the record.
    public static func assess(monitor: MonitorIdentity, displayToken: String, snapshot: Snapshot,report measurement:CapturePipelineReport?=nil) throws -> (record:MonitorLayoutRecord,issues:[String],decisions:[String:String]) {
        var decisions=[String:String]()
        guard snapshot.displays.filter({$0.token==displayToken && $0.role == .external}).count==1 else { throw LayoutError.unsupported }
        var report=measurement ?? CapturePipelineReport()
        report.resetCaptureStages()
        let ordinary=snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}
        if report.spaces.count != ordinary.count {report.spaces=ordinary.enumerated().map{CaptureSpaceCounts(index:$0.offset+1,active:$0.element.active)}}
        let fillReadable=report.count(.axReadable)==0
        var selected=[ObservedWindow]()
        for w in snapshot.windows {
            let bundle=w.selector.bundleID
            if fillReadable {report.increment(.axReadable,bundleID:bundle)}
            if w.spaceIDs.isEmpty {report.increment(.membershipEmpty,bundleID:bundle);report.exclude(.emptyMembership,bundleID:bundle);decisions[w.token]=CaptureReason.emptyMembership.rawValue;continue}
            guard w.spaceIDs.count==1 else{report.increment(.membershipMultiple,bundleID:bundle);report.exclude(.multipleSpaces,bundleID:bundle);decisions[w.token]=CaptureReason.multipleSpaces.rawValue;continue}
            report.increment(.membershipSingle,bundleID:bundle)
            guard let source=snapshot.spaces.first(where:{$0.id==w.spaceIDs[0]}) else{report.increment(.membershipUnknown,bundleID:bundle);report.exclude(.unknownSpace,bundleID:bundle);decisions[w.token]=CaptureReason.unknownSpace.rawValue;continue}
            guard source.displayToken==displayToken else{report.increment(.otherDisplay,bundleID:bundle);report.exclude(.otherDisplay,bundleID:bundle);decisions[w.token]=CaptureReason.otherDisplay.rawValue;continue}
            report.increment(.selectedDisplay,bundleID:bundle);selected.append(w)
        }
        var saved=[SavedWindow](),issues=[String](),labels=[UInt64:String]()
        for w in selected {
            let bundle=w.selector.bundleID
            func reject(_ reason:CaptureReason){report.exclude(reason,bundleID:bundle);decisions[w.token]=reason.rawValue;issues.append(lk("%@：%@", "\(bundle)", "\(reason.rawValue)"))}
            guard w.ordinary else{reject(.notOrdinary);continue}
            guard !w.minimized else{reject(.minimized);continue}
            guard !w.fullScreen else{reject(.fullscreen);continue}
            guard let source=snapshot.spaces.first(where:{$0.id==w.spaceIDs[0]}),source.kind == .ordinary,
                  let slot=ordinary.firstIndex(where:{$0.id==source.id}) else{reject(.nonordinarySpace);continue}
            report.increment(.ordinarySpace,bundleID:bundle)
            guard let display=snapshot.displays.first(where:{$0.token==source.displayToken}),display.visible.valid,w.frame.valid else{reject(.invalidFrame);continue}
            let normalized=w.frame.normalized(in:display.visible)
            guard normalized.valid,normalized.width<=4,normalized.height<=4 else{reject(.invalidFrame);continue}
            guard w.selector.usable else{reject(.unusableSelector);continue}
            guard selected.filter({w.selector.matches($0.selector)}).count==1 else{reject(.ambiguousSelector);continue}
            report.increment(.uniqueSelector,bundleID:bundle)
            let label=labels[source.id] ?? lk("窗口组-%@", "\(UUID().uuidString)");labels[source.id]=label
            saved.append(SavedWindow(selector:w.selector,displayRole:.external,desktopLabel:label,normalizedFrame:normalized,desktopIndex:slot+1))
            report.noteCaptured(bundleID:bundle,spaceIndex:slot+1);decisions[w.token]="captured"
        }
        let profile=Profile(location:monitor.name,windows:saved)
        var record=MonitorLayoutRecord(monitor:monitor,profile:profile)
        record.coverage=ExternalCaptureCoverage(ordinaryDesktopCount:snapshot.spaces.filter{$0.displayToken==displayToken && $0.kind == .ordinary}.count,
            representedDesktopCount:Set(profile.windows.map(\.desktopLabel)).count,readableWindowCount:profile.windows.count,excludedReadableWindowCount:issues.count)
        report.assessmentCompleted=true;report.finish();record.captureReport=report;record.completeness=report.completeness
        try record.validate()
        return (record,issues,decisions)
    }
    public static func inspect(monitor:MonitorIdentity,displayToken:String,snapshot:Snapshot,report:CapturePipelineReport?=nil) throws -> CapturePipelineReport {
        let (record,_)=try capture(monitor:monitor,displayToken:displayToken,snapshot:snapshot,report:report)
        guard let result=record.captureReport else{throw LayoutError.readbackUnavailable};return result
    }
}
