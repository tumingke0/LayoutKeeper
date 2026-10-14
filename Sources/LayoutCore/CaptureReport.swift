// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public enum CaptureCompleteness: String, Codable { case unverified, partial }
public enum CaptureMetric: String, Codable, CaseIterable {
    case applicationsVisited, axEnumerated, cgOwnerMatched, axReadable
    case windowIDResolved = "AXIdentifierResolved"
    case frameReadable, roleSupported, subroleSupported, notMinimized, notFullscreen, minimized, fullscreen
    case membershipSingle, membershipEmpty, membershipMultiple, membershipUnknown, selectedDisplay, otherDisplay, ordinarySpace, uniqueSelector, captured
    case axWindowsListed, axFocusedOrMainAdded, axDuplicateMerged, processLaunchDateMissing, remoteTokenWanted, remoteTokenResolved, remoteTokenElementsInspected, cgNonCandidate
    case cgCandidates, cgMembershipSingle, cgMembershipEmpty, cgMembershipMultiple, cgMembershipUnknown, cgOtherDisplay, cgSelectedDisplay, cgSelectedNonordinary, cgNotInAX, cgSelectedNotInAX
}
public enum CaptureReason: String, Codable, CaseIterable {
    case processIdentityUnavailable, axEnumerationFailure, axEnumerationType, axEnumerationLimit, axTimeoutFailure, axEmptyValue
    case duplicateWindowID, cgWindowMissing, cgOwnerMismatch, cgMembershipReadFailure, membershipReadFailure, windowReadFailure, roleUnsupported, subroleUnsupported, minimizedUnknown, fullscreenUnknown
    case windowIDFailure = "AXIdentifierFailure"
    case remoteTokenUnresolved, remoteTokenSkipped
    case emptyMembership, multipleSpaces, unknownSpace, otherDisplay, nonordinarySpace, notOrdinary, minimized, fullscreen, invalidFrame, unusableSelector, ambiguousSelector
    public var label: String {
        switch self {
        case .processIdentityUnavailable:return lk("进程身份未知")
        case .axEnumerationFailure:return lk("AX 枚举失败")
        case .axEnumerationType:return lk("AX 枚举类型异常")
        case .axEnumerationLimit:return lk("超过枚举上限")
        case .axTimeoutFailure:return lk("AX 超时设置失败")
        case .axEmptyValue:return lk("AX 返回成功但没有值")
        case .windowIDFailure:return lk("窗口 ID 读取失败")
        case .duplicateWindowID:return lk("重复窗口 ID")
        case .cgWindowMissing:return lk("CG 未找到窗口")
        case .cgOwnerMismatch:return lk("CG 所属进程不匹配")
        case .cgMembershipReadFailure:return lk("CG 成员归属读取失败")
        case .membershipReadFailure:return lk("AX 窗口成员归属读取失败")
        case .windowReadFailure:return lk("窗口属性读取失败")
        case .roleUnsupported:return lk("非窗口 role")
        case .subroleUnsupported:return lk("非标准窗口 subrole")
        case .minimizedUnknown:return lk("最小化状态未知")
        case .fullscreenUnknown:return lk("全屏状态未知")
        case .remoteTokenUnresolved:return lk("其他桌面窗口未在时限内取到（状态未知）")
        case .remoteTokenSkipped:return lk("其他桌面窗口未查找（状态未知）")
        case .emptyMembership:return lk("无 Space 成员信息")
        case .multipleSpaces:return lk("属于多个 Space")
        case .unknownSpace:return lk("Space 未识别")
        case .otherDisplay:return lk("属于其他屏幕")
        case .nonordinarySpace:return lk("非普通桌面")
        case .notOrdinary:return lk("普通窗口条件未确认")
        case .minimized:return lk("已最小化")
        case .fullscreen:return lk("已全屏")
        case .invalidFrame:return lk("几何信息无效")
        case .unusableSelector:return lk("缺少可用窗口标识")
        case .ambiguousSelector:return lk("窗口标识不唯一")
        }
    }
}
public struct CaptureAXErrorCount: Codable, Equatable {
    public var operation:String;public var code:Int32;public var count:Int
}
public struct CaptureApplicationCounts: Codable, Equatable {
    public var bundleID:String
    public var counts:[String:Int]=[:]
    public var reasons:[String:Int]=[:]
    public var axErrors:[CaptureAXErrorCount]=[]
    public var emptyAXValues:[String:Int]=[:]
    public func count(_ metric:CaptureMetric) -> Int {counts[metric.rawValue] ?? 0}
}
public struct CaptureSpaceCounts: Codable, Equatable {
    public var index:Int;public var active:Bool
    public var cgCandidates=0;public var cgNotInAX=0;public var captured=0
    public init(index:Int,active:Bool){self.index=index;self.active=active}
}
// Only application identifiers, anonymous Space slots, fixed reason codes and numbers.
// Runtime window/Space IDs and selectors stay in memory; they are not report fields.
public struct CapturePipelineReport: Codable, Equatable {
    public var schemaVersion=1
    public var measuredAt=Date()
    public var elapsedMilliseconds=0
    public var applications:[CaptureApplicationCounts]=[]
    public var spaces:[CaptureSpaceCounts]=[]
    public var globalReasons:[String:Int]=[:]
    public var completeness:CaptureCompleteness = .unverified
    public var assessmentCompleted=false
    public init(){}
    private mutating func appIndex(_ bundleID:String) -> Int {
        if let index=applications.firstIndex(where:{$0.bundleID==bundleID}) {return index}
        applications.append(CaptureApplicationCounts(bundleID:bundleID,counts:Dictionary(uniqueKeysWithValues:CaptureMetric.allCases.map{($0.rawValue,0)})));return applications.count-1
    }
    public mutating func increment(_ metric:CaptureMetric,bundleID:String,by:Int=1) {
        guard by>0 else{return};let index=appIndex(bundleID);applications[index].counts[metric.rawValue,default:0]+=by
    }
    public mutating func exclude(_ reason:CaptureReason,bundleID:String,by:Int=1) {
        guard by>0 else{return};let index=appIndex(bundleID);applications[index].reasons[reason.rawValue,default:0]+=by
    }
    public mutating func axError(operation:String,code:Int32,bundleID:String) {
        let index=appIndex(bundleID)
        if let event=applications[index].axErrors.firstIndex(where:{$0.operation==operation && $0.code==code}) {applications[index].axErrors[event].count+=1}
        else {applications[index].axErrors.append(CaptureAXErrorCount(operation:operation,code:code,count:1))}
    }
    public mutating func emptyAXValue(operation:String,bundleID:String) {
        let index=appIndex(bundleID);applications[index].emptyAXValues[operation,default:0]+=1
        exclude(.axEmptyValue,bundleID:bundleID)
    }
    public func count(_ metric:CaptureMetric,bundleID:String?=nil) -> Int {
        applications.filter{bundleID==nil || $0.bundleID==bundleID}.reduce(0){$0+$1.count(metric)}
    }
    public func reason(_ reason:CaptureReason,bundleID:String?=nil) -> Int {
        applications.filter{bundleID==nil || $0.bundleID==bundleID}.reduce(0){$0+($1.reasons[reason.rawValue] ?? 0)}
    }
    public mutating func noteCGCandidate(bundleID:String,selectedOrdinarySpaceIndex:Int?,seenInAX:Bool) {
        increment(.cgCandidates,bundleID:bundleID)
        if !seenInAX {increment(.cgNotInAX,bundleID:bundleID)}
        guard let slot=selectedOrdinarySpaceIndex,let index=spaces.firstIndex(where:{$0.index==slot}) else{return}
        increment(.cgSelectedDisplay,bundleID:bundleID);spaces[index].cgCandidates+=1
        if !seenInAX {increment(.cgSelectedNotInAX,bundleID:bundleID);spaces[index].cgNotInAX+=1}
    }
    public mutating func noteWindowID(bundleID:String,axPID:Int32,cgOwners:[Int32]) -> Bool {
        increment(.windowIDResolved,bundleID:bundleID)
        guard !cgOwners.isEmpty else{exclude(.cgWindowMissing,bundleID:bundleID);return false}
        guard cgOwners.count==1,cgOwners[0]==axPID else{exclude(.cgOwnerMismatch,bundleID:bundleID);return false}
        increment(.cgOwnerMatched,bundleID:bundleID);return true
    }
    public mutating func noteCaptured(bundleID:String,spaceIndex:Int) {
        increment(.captured,bundleID:bundleID)
        if let index=spaces.firstIndex(where:{$0.index==spaceIndex}) {spaces[index].captured+=1}
    }
    public mutating func resetCaptureStages() {
        let metrics:[CaptureMetric]=[.membershipSingle,.membershipEmpty,.membershipMultiple,.membershipUnknown,.selectedDisplay,.otherDisplay,.ordinarySpace,.uniqueSelector,.captured]
        let reasons:[CaptureReason]=[.emptyMembership,.multipleSpaces,.unknownSpace,.otherDisplay,.nonordinarySpace,.notOrdinary,.minimized,.fullscreen,.invalidFrame,.unusableSelector,.ambiguousSelector]
        for i in applications.indices {for metric in metrics {applications[i].counts[metric.rawValue]=0};for reason in reasons {applications[i].reasons.removeValue(forKey:reason.rawValue)}}
        for i in spaces.indices {spaces[i].captured=0}
    }
    public mutating func finish() {
        let uncertainty:Set<CaptureReason>=[.processIdentityUnavailable,.axEnumerationFailure,.axEnumerationType,.axEnumerationLimit,.axTimeoutFailure,.axEmptyValue,.windowIDFailure,.cgWindowMissing,.cgOwnerMismatch,.cgMembershipReadFailure,.membershipReadFailure,.windowReadFailure,.remoteTokenUnresolved,.remoteTokenSkipped,.emptyMembership,.multipleSpaces,.unknownSpace,.notOrdinary,.invalidFrame,.unusableSelector,.ambiguousSelector]
        completeness = count(.cgSelectedNotInAX)>0 || !globalReasons.isEmpty || uncertainty.contains(where:{reason($0)>0}) || applications.contains(where:{!$0.axErrors.isEmpty}) ? .partial : .unverified
    }
    public var summary:String {
        if globalReasons["inspectionBudgetExceeded",default:0]>0 {return lk("检查达到读取时限；已确认 %@ 个候选可保存，但总量未知，完整性尚未确认。", "\(count(.captured))")}
        guard assessmentCompleted else{return lk("检查未完成；当前只有局部读取计数，可保存数量未知。完整性尚未确认。")}
        let represented=spaces.filter{$0.captured>0}.count
        let status=completeness == .partial ? lk("存在读取失败或未覆盖候选，采集可能不完整。") : lk("完整性尚未确认。")
        let unknown=reason(.remoteTokenUnresolved)+reason(.remoteTokenSkipped)
        let remote=unknown>0 ? lk("有 %@ 个其他桌面上的窗口没能读到，状态未知（不代表已关闭）。", "\(unknown)") : ""
        return lk("可保存 %@ 个窗口，覆盖 %@/%@ 个普通桌面。", "\(count(.captured))", "\(represented)", "\(spaces.count)")+status+remote+lk("外屏候选窗口中 %@ 个未被 AX 对应；候选不等于可保存窗口。", "\(count(.cgSelectedNotInAX))")
    }
    public func validate(capturedCount:Int) throws {
        guard schemaVersion==1,assessmentCompleted,elapsedMilliseconds>=0,count(.captured)==capturedCount,spaces.reduce(0,{$0+$1.captured})==capturedCount,
              Set(applications.map(\.bundleID)).count==applications.count,Set(spaces.map(\.index)).count==spaces.count,
              globalReasons.values.allSatisfy({$0>0}),
              applications.allSatisfy({!$0.bundleID.isEmpty && $0.counts.allSatisfy{CaptureMetric(rawValue:$0.key) != nil && $0.value>=0} && $0.reasons.allSatisfy{CaptureReason(rawValue:$0.key) != nil && $0.value>=0} && $0.axErrors.allSatisfy{$0.count>0} && $0.emptyAXValues.values.allSatisfy{$0>0} && ($0.count(.applicationsVisited)==0 || ($0.count(.captured)<=$0.count(.cgOwnerMatched) && $0.count(.captured)<=$0.count(.axReadable)))}),
              spaces.allSatisfy({$0.index>0 && $0.cgCandidates>=0 && $0.cgNotInAX>=0 && $0.cgNotInAX<=$0.cgCandidates && $0.captured>=0}) else{throw LayoutError.invalidProfile}
    }
    public func json() -> String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        return (try? String(data:encoder.encode(self),encoding:.utf8)) ?? "{}"
    }
}
