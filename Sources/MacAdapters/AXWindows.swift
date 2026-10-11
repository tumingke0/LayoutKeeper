// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import Darwin
import LayoutCore

public struct AXFailure: Error, CustomStringConvertible {
    public let operation: String; public let code: Int32
    public var description: String { "\(operation): AXError \(code)" }
}
public final class AXWindows: WindowBackend {
    public let session=UUID()
    public let spaces: ReadOnlySpaces
    public var writesApproved=false
    public private(set) var issues: [String]=[]
    public private(set) var latestCaptureReport=CapturePipelineReport()
    private var collectingReport=false
        private var cgOwners=[UInt32:Set<Int32>]()
    private var axWindowIDs=[Int32:Set<UInt32>]()
    private var inspectionDeadline:TimeInterval?
    private struct Handle { var element: AXUIElement; var pid: pid_t; var windowID: UInt32; var bundleID: String; var launchedAt: Date? }
    private var handles: [String:Handle]=[:]
    public init(spaces: ReadOnlySpaces) { self.spaces=spaces }
    private func recordIssue(_ issue: String) {
        if !issues.contains(issue) { issues.append(issue) }
    }
    private func count(_ metric:CaptureMetric,_ bundle:String) {if collectingReport {latestCaptureReport.increment(metric,bundleID:bundle)}}
    private func inspectionExpired() -> Bool {
        guard collectingReport,let deadline=inspectionDeadline,ProcessInfo.processInfo.systemUptime>=deadline else{return false}
        latestCaptureReport.globalReasons["inspectionBudgetExceeded"]=1;return true
    }
    private func exclude(_ reason:CaptureReason,_ bundle:String,error:Error?=nil) {
        guard collectingReport else{return}
        latestCaptureReport.exclude(reason,bundleID:bundle)
        if let error {recordAXError(error,bundle)}
    }
    private func recordAXError(_ error:Error,_ bundle:String) {
        guard collectingReport else{return}
        if let error=error as? AXFailure {latestCaptureReport.axError(operation:error.operation,code:error.code,bundleID:bundle)}
        else if let error=error as? AXReadValueError,case let .emptyValue(operation)=error {latestCaptureReport.emptyAXValue(operation:operation,bundleID:bundle)}
    }
    private func attribute(_ element: AXUIElement, _ key: String) throws -> CFTypeRef {
        try AXAttributeReader.read(operation:key) { value in
            AXUIElementCopyAttributeValue(element,key as CFString,&value)
        }
    }
    private func optionalAttribute(_ element: AXUIElement, _ key: String, token: String) -> CFTypeRef? {
        do { return try attribute(element,key) }
        catch {recordIssue("\(token)：\(error)");if let bundle=handles[token]?.bundleID {recordAXError(error,bundle)};return nil}
    }
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private static let getWindowFunction: GetWindowFunction? = {
        guard let library=dlopen(nil,RTLD_LAZY), let symbol=dlsym(library,"_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol,to:GetWindowFunction.self)
    }()
    private func cgID(_ element: AXUIElement) throws -> UInt32 {
        guard let function=Self.getWindowFunction else { throw LayoutError.unsupported }
        var id: UInt32=0
        let status=function(element,&id)
        guard status==0 else { throw AXFailure(operation:"_AXUIElementGetWindow",code:status) }
        guard id > 0 else { throw LayoutError.readbackUnavailable }
        return id
    }
    // Budgets for looking up windows on Spaces that are not currently shown. The scan runs on the main thread.
    public var remoteSearchPerApp: TimeInterval=1.5
    public var remoteSearchTotal: TimeInterval=8
    public var remoteElementCap: UInt64=200_000
    public private(set) var captureTrace: [CaptureTraceEntry]=[]
    private let remoteLocator=RemoteWindowLocator()
    private var inventory=CGWindowInventory(candidates:[],owners:[:],available:false,traitsAvailable:false)
    private var axSources=[UInt32:AXWindowSource]()
    private var remoteUnresolved=[UInt32:CaptureReason]()
    private func readElements(_ application: AXUIElement, _ key: String, bundle: String) throws -> [AXUIElement] {
        let value=try attribute(application,key)
        if key==kAXWindowsAttribute {
            guard let list=value as? [AXUIElement] else { throw AXReadTypeError() }
            return list
        }
        guard CFGetTypeID(value)==AXUIElementGetTypeID() else { throw AXReadTypeError() }
        return [value as! AXUIElement]
    }
    private struct AXReadTypeError: Error {}
    /// Shared validation for every discovery source: CG ownership must match the AX pid exactly once.
    @discardableResult
    private func register(_ element: AXUIElement, id: UInt32, source: AXWindowSource, app: NSRunningApplication, bundle: String) -> Bool {
        guard latestCaptureReport.noteWindowID(bundleID:bundle,axPID:app.processIdentifier,cgOwners:Array(cgOwners[id] ?? [])) else{recordIssue("\(bundle)：CG 窗口归属未确认");return false}
        let token="\(app.processIdentifier):\(id)"
        guard handles[token]==nil else{exclude(.duplicateWindowID,bundle);return false}
        axWindowIDs[app.processIdentifier,default:[]].insert(id)
        axSources[id]=source
        handles[token]=Handle(element:element,pid:app.processIdentifier,windowID:id,bundleID:bundle,launchedAt:app.launchDate)
        return true
    }
    // Explicit user-triggered scan. It never requests permission, activates apps, or switches Spaces.
    public func scan(onlyPID: pid_t? = nil,selectedDisplayToken:String?=nil,inspectionBudget:TimeInterval?=nil) throws -> Snapshot {
        latestCaptureReport=CapturePipelineReport();collectingReport=true
        let start=ProcessInfo.processInfo.systemUptime
        inspectionDeadline=inspectionBudget.map{start+max(0,$0)}
        defer{latestCaptureReport.elapsedMilliseconds=Int((ProcessInfo.processInfo.systemUptime-start)*1000);latestCaptureReport.finish();collectingReport=false;inspectionDeadline=nil}
        guard AXIsProcessTrusted() else {latestCaptureReport.globalReasons["axPermissionUnavailable"]=1;throw LayoutError.permissionRequired}
        handles.removeAll(); issues=[];cgOwners=[:];axWindowIDs=[:];axSources=[:];remoteUnresolved=[:];captureTrace=[]
        let apps=NSWorkspace.shared.runningApplications.filter { app in
            if app.processIdentifier==getpid() { return false }
            if let onlyPID { return app.processIdentifier==onlyPID }
            return app.activationPolicy == .regular
        }
        inventory=CGWindowInventory.collect(spaces:spaces,includePIDs:Set(apps.map(\.processIdentifier)))
        if !inventory.available {latestCaptureReport.globalReasons["cgEnumerationUnavailable"]=1}
        else if !inventory.traitsAvailable && inventory.candidates.contains(where:{$0.layer==0}) {latestCaptureReport.globalReasons["windowServerTraitsUnavailable"]=1}
        cgOwners=inventory.owners
        let remoteDeadline=start+remoteSearchTotal
        for app in apps {
            if inspectionExpired(){break}
            guard let bundle=app.bundleIdentifier else {latestCaptureReport.globalReasons["applicationIdentifierUnavailable",default:0]+=1;continue}
            count(.applicationsVisited,bundle)
            // Finder and a few system apps can report no launch date; identity then rests on pid + AX pid + window ID.
            if app.launchDate==nil {count(.processLaunchDateMissing,bundle)}
            let application=AXUIElementCreateApplication(app.processIdentifier)
            let timeout=AXUIElementSetMessagingTimeout(application,0.25)
            if timeout != .success {let error=AXFailure(operation:"AXMessagingTimeout",code:timeout.rawValue);exclude(.axTimeoutFailure,bundle,error:error);recordIssue("\(bundle)：\(error)");continue}
            var gathered=[(id:UInt32?,value:(AXUIElement,AXWindowSource))]()
            var appUnresponsive=false
            do {
                let windows=try readElements(application,kAXWindowsAttribute,bundle:bundle)
                latestCaptureReport.increment(.axEnumerated,bundleID:bundle,by:windows.count)
                count(.axWindowsListed,bundle)
                if windows.count>100 {latestCaptureReport.exclude(.axEnumerationLimit,bundleID:bundle,by:windows.count-100);issues.append("\(bundle)：只读取前 100 个可枚举窗口，本次不是完整采集")}
                for element in windows.prefix(100) {gathered.append((nil,(element,.windowsList)))}
            } catch is AXReadTypeError {
                exclude(.axEnumerationType,bundle);recordIssue("\(bundle)：AXWindows 返回的值类型不正确")
            } catch {
                // A failed read is unknown, not "no windows"; still try the focused/main window below.
                exclude(.axEnumerationFailure,bundle,error:error);recordIssue("\(bundle)：\(error)")
                if let failure=error as? AXFailure, failure.code==AXError.cannotComplete.rawValue {appUnresponsive=true}
            }
            // Focused and main window are not limited to the visible Spaces.
            if !appUnresponsive {
                for (key,source) in [(kAXFocusedWindowAttribute,AXWindowSource.focusedWindow),(kAXMainWindowAttribute,AXWindowSource.mainWindow)] {
                    if let element=try? readElements(application,key,bundle:bundle).first {gathered.append((nil,(element,source)))}
                }
            }
            var withIDs=[(id:UInt32?,value:(AXUIElement,AXWindowSource))]()
            for item in gathered {
                if inspectionExpired(){break}
                let element=item.value.0
                let timeout=AXUIElementSetMessagingTimeout(element,0.25)
                if timeout != .success {let error=AXFailure(operation:"AXMessagingTimeout",code:timeout.rawValue);exclude(.axTimeoutFailure,bundle,error:error);recordIssue("\(bundle)：\(error)");continue}
                do { withIDs.append((try cgID(element),item.value)) }
                catch {
                    // Focused/main are only extra sources; Finder's list also carries a desktop element with window ID 0.
                    let finderDesktop=bundle=="com.apple.finder" && (error as? LayoutError) == .readbackUnavailable
                    if item.value.1 == .windowsList && !finderDesktop {exclude(.windowIDFailure,bundle,error:error);recordIssue("\(bundle)：\(error)")}
                }
            }
            let unique=WindowCandidateRules.uniqueByWindowID(withIDs)
            latestCaptureReport.increment(.axDuplicateMerged,bundleID:bundle,by:unique.duplicates)
            for item in unique.unique {
                if register(item.value.0,id:item.id,source:item.value.1,app:app,bundle:bundle), item.value.1 != .windowsList {count(.axFocusedOrMainAdded,bundle)}
            }
            // Windows on Spaces that are not shown: find them by remote element token.
            let wanted=WindowCandidateRules.wantedWindowIDs(pid:app.processIdentifier,candidates:inventory.candidates,resolved:axWindowIDs[app.processIdentifier] ?? [])
            guard !wanted.isEmpty else {continue}
            latestCaptureReport.increment(.remoteTokenWanted,bundleID:bundle,by:wanted.count)
            func skip(_ global:String) {
                for id in wanted {remoteUnresolved[id] = .remoteTokenSkipped}
                latestCaptureReport.exclude(.remoteTokenSkipped,bundleID:bundle,by:wanted.count)
                latestCaptureReport.globalReasons[global,default:0]+=1
            }
            if appUnresponsive {skip("remoteTokenAppUnresponsive");continue}
            guard remoteLocator.isAvailable else {skip("remoteTokenUnavailable");continue}
            let now=ProcessInfo.processInfo.systemUptime
            let deadline=min(remoteDeadline,inspectionDeadline ?? .infinity)
            guard now<deadline else {skip("remoteTokenBudgetExhausted");continue}
            let processKey="\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
            let result=remoteLocator.search(pid:app.processIdentifier,processKey:processKey,wanted:wanted,timeBudget:remoteSearchPerApp,elementCap:remoteElementCap,deadline:deadline) {[weak self] element in
                try? self?.cgID(element)
            }
            latestCaptureReport.increment(.remoteTokenElementsInspected,bundleID:bundle,by:result.inspected)
            for (id,element) in result.found.sorted(by:{$0.key<$1.key}) {
                if register(element,id:id,source:.remoteToken,app:app,bundle:bundle) {count(.remoteTokenResolved,bundle)}
            }
            if !result.unresolved.isEmpty {
                // Not found within the budget: unknown, never reported as closed.
                for id in result.unresolved {remoteUnresolved[id] = .remoteTokenUnresolved}
                latestCaptureReport.exclude(.remoteTokenUnresolved,bundleID:bundle,by:result.unresolved.count)
                recordIssue("\(bundle)：\(result.unresolved.count) 个其他桌面窗口未在时限内取到（\(result.stop.rawValue)），状态未知")
                if result.stop == .timeBudget || result.stop == .deadline {latestCaptureReport.globalReasons["remoteTokenBudgetExhausted",default:0]+=1}
            }
        }
        let captured:Snapshot
        do{captured=try snapshot()}catch{latestCaptureReport.globalReasons["snapshotUnavailable"]=1;throw error}
        collectCGCoverage(snapshot:captured,apps:apps,selectedDisplayToken:selectedDisplayToken)
        if captured.windows.count<handles.count { issues.append("\(handles.count-captured.windows.count) 个已枚举窗口无法回读，未保存其布局") }
        return captured
    }
    /// Fills trace outcomes from LayoutCore decisions keyed by window token. Runtime only.
    public func applyCaptureDecisions(_ decisions: [String:String]) {
        var byID=[UInt32:String]()
        for (token,decision) in decisions { if let handle=handles[token] {byID[handle.windowID]=decision} }
        for index in captureTrace.indices { if let decision=byID[captureTrace[index].windowID] {captureTrace[index].outcome=decision} }
    }
    private func collectCGCoverage(snapshot:Snapshot,apps:[NSRunningApplication],selectedDisplayToken:String?) {
        let ordinary=snapshot.spaces.filter{$0.displayToken==selectedDisplayToken && $0.kind == .ordinary}
        latestCaptureReport.spaces=ordinary.enumerated().map{CaptureSpaceCounts(index:$0.offset+1,active:$0.element.active)}
        var bundleByPID=[Int32:String]()
        for app in apps {if let bundle=app.bundleIdentifier {bundleByPID[app.processIdentifier]=bundle}}
        let readable=Set(snapshot.windows.map(\.token))
        for row in inventory.candidates where row.layer==0 {
            guard let bundle=bundleByPID[row.ownerPID] else{continue}
            let id=row.windowID
            var slot:Int?, placement="none"
            if let membership=row.spaceIDs {
                if membership.isEmpty {count(.cgMembershipEmpty,bundle)}
                else if membership.count>1 {count(.cgMembershipMultiple,bundle);placement="multipleSpaces"}
                else {
                    count(.cgMembershipSingle,bundle)
                    if let found=snapshot.spaces.first(where:{$0.id==membership[0]}) {
                        if let index=ordinary.firstIndex(where:{$0.id==found.id}) {slot=index+1;placement="selectedDisplay"}
                        else if found.displayToken != selectedDisplayToken {count(.cgOtherDisplay,bundle);placement="otherDisplay"}
                        else{count(.cgSelectedNonordinary,bundle);placement="selectedNonordinary"}
                    } else{count(.cgMembershipUnknown,bundle);placement="unknownSpace"}
                }
            } else {exclude(.cgMembershipReadFailure,bundle);count(.cgMembershipUnknown,bundle);placement="unknownSpace"}
            let token="\(row.ownerPID):\(id)"
            let seen=axWindowIDs[row.ownerPID]?.contains(id)==true
            let exclusion=WindowCandidateRules.exclusion(row)
            let outcome:String
            if seen {outcome=readable.contains(token) ? "notAssessed" : CaptureReason.windowReadFailure.rawValue}
            else if exclusion != nil {outcome="notCandidate"}
            else {outcome=remoteUnresolved[id]?.rawValue ?? "notInAX"}
            captureTrace.append(CaptureTraceEntry(bundleID:bundle,windowID:id,width:Int(row.bounds.width),height:Int(row.bounds.height),spaceSlot:slot,placement:placement,exclusion:exclusion,axSource:seen ? axSources[id] : nil,outcome:outcome))
            if exclusion != nil, exclusion != .membershipUnreadable {count(.cgNonCandidate,bundle);continue}
            latestCaptureReport.noteCGCandidate(bundleID:bundle,selectedOrdinarySpaceIndex:slot,seenInAX:seen)
        }
    }
    public func snapshot() throws -> Snapshot {
        let displays=MacEnvironment.displays()
        guard displays.count <= 1 || NSScreen.screensHaveSeparateSpaces else { throw LayoutError.unsupported }
        let found=try spaces.spaces(displays:displays)
        var windows=[ObservedWindow]()
        for token in handles.keys.sorted() {
            if inspectionExpired(){break}
            do {
                if let window=try readWindow(token:token) {windows.append(window);if let bundle=handles[token]?.bundleID {count(.axReadable,bundle)}}
                else {if let bundle=handles[token]?.bundleID {exclude(.windowReadFailure,bundle)};recordIssue("\(token)：窗口已关闭、所属进程不可用或窗口引用已改变")}
            } catch {if let bundle=handles[token]?.bundleID {exclude(.windowReadFailure,bundle,error:error)};recordIssue("\(token)：窗口回读失败：\(error)")}
        }
        return Snapshot(session:session,topology:MacEnvironment.topology(displays:displays,spaces:found),displays:displays,spaces:found,windows:windows)
    }
    public func readWindow(token: String) throws -> ObservedWindow? {
        guard let h=handles[token] else{return nil}
        guard let app=NSRunningApplication(processIdentifier:h.pid),!app.isTerminated,app.bundleIdentifier==h.bundleID,app.launchDate==h.launchedAt else{exclude(.processIdentityUnavailable,h.bundleID);return nil}
        var actualPID: pid_t=0
        let pidStatus=AXUIElementGetPid(h.element,&actualPID)
        guard pidStatus == .success else { throw AXFailure(operation:"AXWindowPID",code:pidStatus.rawValue) }
        guard actualPID==h.pid else{exclude(.processIdentityUnavailable,h.bundleID);return nil}
        guard try cgID(h.element)==h.windowID else{exclude(.windowIDFailure,h.bundleID);return nil}
        let position=try attribute(h.element,kAXPositionAttribute), size=try attribute(h.element,kAXSizeAttribute)
        guard CFGetTypeID(position)==AXValueGetTypeID(), CFGetTypeID(size)==AXValueGetTypeID() else { throw LayoutError.readbackUnavailable }
        let p=position as! AXValue, z=size as! AXValue
        var point=CGPoint.zero; var dimensions=CGSize.zero
        guard AXValueGetValue(p,.cgPoint,&point), AXValueGetValue(z,.cgSize,&dimensions) else { throw LayoutError.readbackUnavailable }
        count(.frameReadable,h.bundleID)
        let title=optionalAttribute(h.element,kAXTitleAttribute,token:token) as? String ?? ""
        let document=optionalAttribute(h.element,kAXDocumentAttribute,token:token)
        let path=(document as? String) ?? (document as? URL)?.absoluteString
        let fullscreen=optionalAttribute(h.element,"AXFullScreen",token:token) as? Bool
        let minimized=optionalAttribute(h.element,kAXMinimizedAttribute,token:token) as? Bool
        let role=optionalAttribute(h.element,kAXRoleAttribute,token:token) as? String
        let subrole=optionalAttribute(h.element,kAXSubroleAttribute,token:token) as? String
        if role==kAXWindowRole {count(.roleSupported,h.bundleID)}else{exclude(.roleUnsupported,h.bundleID)}
        if subrole==kAXStandardWindowSubrole {count(.subroleSupported,h.bundleID)}else{exclude(.subroleUnsupported,h.bundleID)}
        if minimized==false {count(.notMinimized,h.bundleID)}else if minimized==true {count(.minimized,h.bundleID)}else{exclude(.minimizedUnknown,h.bundleID)}
        if fullscreen==false {count(.notFullscreen,h.bundleID)}else if fullscreen==true {count(.fullscreen,h.bundleID)}else{exclude(.fullscreenUnknown,h.bundleID)}
        let ordinary=role==kAXWindowRole && subrole==kAXStandardWindowSubrole && fullscreen != nil && minimized != nil
        let membership:[UInt64]
        do{membership=try spaces.membership(windowID:h.windowID)}catch{exclude(.membershipReadFailure,h.bundleID);throw error}
        return ObservedWindow(token:token,selector:WindowSelector(bundleID:h.bundleID,document:path,title:title),frame:Rect(point.x,point.y,dimensions.width,dimensions.height),spaceIDs:membership,ordinary:ordinary,minimized:minimized ?? false,fullScreen:fullscreen ?? false,processStartedAt:h.launchedAt)
    }
    public func verifiedMoveWindow(_ window: ObservedWindow) throws -> VerifiedAXWindow {
        guard writesApproved,AXIsProcessTrusted() else { throw LayoutError.permissionRequired }
        guard let handle=handles[window.token],let fresh=try readWindow(token:window.token),fresh.selector==window.selector,
              fresh.processStartedAt==window.processStartedAt,fresh.spaceIDs==window.spaceIDs,fresh.frame.near(window.frame,tolerance:0.01),
              fresh.ordinary,!fresh.fullScreen,!fresh.minimized else { throw LayoutError.readbackUnavailable }
        let rows=CGWindowListCopyWindowInfo(.optionIncludingWindow,handle.windowID) as? [[String:Any]] ?? []
        let matches=rows.filter{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==handle.windowID}
        guard matches.count==1,let owner=matches[0][kCGWindowOwnerPID as String] as? NSNumber,owner.int32Value==handle.pid else { throw LayoutError.readbackUnavailable }
        // Moves need a known process start time; windows of apps without a launch date are read-only.
        guard let startedAt=handle.launchedAt else { throw LayoutError.readbackUnavailable }
        return VerifiedAXWindow(element:handle.element,claim:WindowOwnershipClaim(token:window.token,axPID:handle.pid,cgPID:owner.int32Value,windowID:handle.windowID,processStartedAt:startedAt,bundleID:handle.bundleID),selector:fresh.selector)
    }
    public func setFrame(window: ObservedWindow, to frame: Rect) throws {
        guard writesApproved, AXIsProcessTrusted() else { throw LayoutError.permissionRequired }
        guard frame.valid, let h=handles[window.token], let fresh=try readWindow(token:window.token), fresh.selector==window.selector,fresh.processStartedAt==window.processStartedAt,fresh.frame.near(window.frame,tolerance:0.01),
              fresh.ordinary, !fresh.minimized, !fresh.fullScreen, fresh.spaceIDs==window.spaceIDs, fresh.spaceIDs.count==1 else { throw LayoutError.readbackUnavailable }
        var size=CGSize(width:frame.width,height:frame.height); var point=CGPoint(x:frame.x,y:frame.y)
        guard let sizeValue=AXValueCreate(.cgSize,&size), let positionValue=AXValueCreate(.cgPoint,&point) else { throw LayoutError.readbackUnavailable }
        var movable=DarwinBoolean(false); var resizable=DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(h.element,kAXPositionAttribute as CFString,&movable) == .success,
              AXUIElementIsAttributeSettable(h.element,kAXSizeAttribute as CFString,&resizable) == .success, movable.boolValue, resizable.boolValue else { throw LayoutError.unsupported }
        // Some apps (Chromium-based ones in particular) animate or reinterpret frame writes while the app-level
        // AXEnhancedUserInterface flag is on. Turn it off only for these writes and always restore it.
        let application=AXUIElementCreateApplication(h.pid)
        var enhanced: CFTypeRef?
        let enhancedOn=AXUIElementCopyAttributeValue(application,"AXEnhancedUserInterface" as CFString,&enhanced) == .success && (enhanced as? Bool)==true
        if enhancedOn { _=AXUIElementSetAttributeValue(application,"AXEnhancedUserInterface" as CFString,kCFBooleanFalse) }
        defer { if enhancedOn { _=AXUIElementSetAttributeValue(application,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue) } }
        func write(_ step: FrameWriteStep) throws {
            let status=step == .size ? AXUIElementSetAttributeValue(h.element,kAXSizeAttribute as CFString,sizeValue) : AXUIElementSetAttributeValue(h.element,kAXPositionAttribute as CFString,positionValue)
            guard status == .success else { throw AXFailure(operation:step == .size ? "AXSize" : "AXPosition",code:status.rawValue) }
            // Identity and Space must still hold between the two writes.
            guard let current=try readWindow(token:window.token),current.selector==window.selector,current.processStartedAt==window.processStartedAt,
                  current.ordinary,!current.fullScreen,!current.minimized,current.spaceIDs==window.spaceIDs else { throw LayoutError.readbackUnavailable }
        }
        func settled() -> Bool {
            for attempt in 0..<4 {
                if attempt>0 { usleep(50_000) }
                if let current=try? readWindow(token:window.token),current.frame.near(frame) { return true }
            }
            return false
        }
        let order=FrameWritePlanner.order(current:fresh.frame,target:frame)
        for step in order { try write(step) }
        if !settled() { for step in FrameWritePlanner.retry(after:order) { try write(step) } }
    }
}
