// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import ObjectiveC
import Darwin
import LayoutCore

// Private READ APIs are isolated here and dynamically resolved. No injection or hidden-symbol scanning.
public final class ReadOnlySpaces: SpacesBackend {
    private let handle: UnsafeMutableRawPointer?
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    public let canMove = false
    public init() { handle=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",RTLD_LAZY | RTLD_LOCAL) }
    deinit { if let handle { dlclose(handle) } }
    private func function<T>(_ name: String, _ type: T.Type) -> T? { guard let handle, let symbol=dlsym(handle,name) else { return nil }; return unsafeBitCast(symbol,to:type) }
    public func move(window: ObservedWindow, to space: UInt64) throws { throw LayoutError.unsupported }
    public func evidence() -> [String: Bool] {
        let exported=["SLSMainConnectionID","SLSCopyManagedDisplaySpaces","SLSCopySpacesForWindows","SLSPerformAsynchronousBridgedWindowManagementOperation","_ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"]
        var result: [String: Bool] = [:]
        for name in exported { result[name] = handle.map{dlsym($0,name) != nil} ?? false }
        result["class:SLSBridgedMoveWindowsToManagedSpaceOperation"] = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") != nil
        return result
    }
    public func operationSelectors() -> [String] {
        guard let cls=NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return [] }
        var count: UInt32=0
        guard let list=class_copyMethodList(cls,&count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.sorted()
    }
    public func operationRuntime() -> [[String: Any]] {
        var rows: [[String: Any]]=[]
        var cls: AnyClass?=NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
        while let current=cls, NSStringFromClass(current) != "NSObject" {
            var count: UInt32=0
            if let list=class_copyMethodList(current,&count) {
                let methods=(0..<Int(count)).map { index in
                    ["selector":NSStringFromSelector(method_getName(list[index])),"encoding":method_getTypeEncoding(list[index]).map{String(cString:$0)} ?? "unknown"]
                }
                rows.append(["class":NSStringFromClass(current),"methods":methods]); free(list)
            }
            cls=class_getSuperclass(current)
        }
        return rows
    }
    public func spaces(displays: [Display]) throws -> [Space] {
        guard let connection=function("SLSMainConnectionID",Connection.self), let copy=function("SLSCopyManagedDisplaySpaces",CopyDisplays.self),
              let array=copy(connection())?.takeRetainedValue() else { throw LayoutError.readbackUnavailable }
        guard let rows=array as? [[String: Any]], !rows.isEmpty else { throw LayoutError.readbackUnavailable }
        var result: [Space]=[]
        for row in rows {
            guard let identifier=row["Display Identifier"] as? String else { continue }
            let token=identifier == "Main" ? displays.first?.token : displays.first(where:{$0.token.caseInsensitiveCompare(identifier) == .orderedSame})?.token
            guard let token, let rawSpaces=row["Spaces"] as? [[String:Any]] else { continue }
            let current=(row["Current Space"] as? [String:Any])?["ManagedSpaceID"] as? NSNumber
            for raw in rawSpaces {
                guard let id=raw["ManagedSpaceID"] as? NSNumber, id.uint64Value > 0 else { continue }
                let kind: SpaceKind = (raw["type"] as? NSNumber)?.intValue == 0 ? .ordinary : ((raw["type"] as? NSNumber)?.intValue == 4 ? .fullScreenOrSplit : .unknown)
                let uuid=(raw["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                result.append(Space(id:id.uint64Value,displayToken:token,kind:kind,active:id==current,uuid:uuid))
            }
        }
        guard !result.isEmpty else { throw LayoutError.readbackUnavailable }
        return result
    }
    public func membership(windowID: UInt32) throws -> [UInt64] {
        guard let connection=function("SLSMainConnectionID",Connection.self), let copy=function("SLSCopySpacesForWindows",CopyWindowSpaces.self),
              let array=copy(connection(),7,[NSNumber(value:windowID)] as CFArray)?.takeRetainedValue(), let ids=array as? [NSNumber] else { throw LayoutError.readbackUnavailable }
        return ids.map(\.uint64Value).sorted()
    }
    private typealias QueryWindows = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyQueryIterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias IteratorAdvance = @convention(c) (CFTypeRef) -> Bool
    private typealias IteratorUInt32 = @convention(c) (CFTypeRef) -> UInt32
    private typealias IteratorUInt64 = @convention(c) (CFTypeRef) -> UInt64
    /// Batch read of parent ID, attribute and tag words for the given windows.
    /// Returns nil when the SkyLight query functions are missing or the query fails, so callers can fall back.
    /// Read only; results are hints for discovery statistics, never a reason to save or skip a window by themselves.
    public func windowServerTraits(windowIDs: [UInt32]) -> [UInt32: WindowServerTraits]? {
        let requested=Array(Set(windowIDs.filter{$0 != 0}))
        guard !requested.isEmpty else { return [:] }
        guard let connection=function("SLSMainConnectionID",Connection.self),
              let query=function("SLSWindowQueryWindows",QueryWindows.self),
              let copyIterator=function("SLSWindowQueryResultCopyWindows",CopyQueryIterator.self),
              let advance=function("SLSWindowIteratorAdvance",IteratorAdvance.self),
              let windowID=function("SLSWindowIteratorGetWindowID",IteratorUInt32.self),
              let parentID=function("SLSWindowIteratorGetParentID",IteratorUInt32.self),
              let tags=function("SLSWindowIteratorGetTags",IteratorUInt64.self),
              let attributes=function("SLSWindowIteratorGetAttributes",IteratorUInt64.self) else { return nil }
        let wanted=Set(requested)
        let ids=requested.map{NSNumber(value:$0)} as CFArray
        guard let result=query(connection(),ids,Int32(requested.count))?.takeRetainedValue(),
              let iterator=copyIterator(result)?.takeRetainedValue() else { return nil }
        var traits=[UInt32: WindowServerTraits]()
        var steps=0
        while steps < requested.count, advance(iterator) {
            steps+=1
            let id=windowID(iterator)
            guard wanted.contains(id) else { continue }
            traits[id]=WindowServerTraits(parentID:parentID(iterator),attributes:attributes(iterator),tags:tags(iterator))
        }
        return traits
    }
}

public enum MacEnvironment {
    public static func displays() -> [Display] {
        let screens=NSScreen.screens
        let top=screens.first?.frame.maxY ?? 0
        return screens.compactMap { screen in
            guard let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid=CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return nil }
            let token=CFUUIDCreateString(nil,uuid)! as String
            let f=screen.visibleFrame
            return Display(token:token,name:screen.localizedName,role:CGDisplayIsBuiltin(id.uint32Value) != 0 ? .builtIn : .external,visible:Rect(f.minX,top-f.maxY,f.width,f.height))
        }
    }
    public static func topology(displays: [Display], spaces: [Space]) -> String {
        let d=displays.map{"\($0.token):\($0.role.rawValue):\($0.visible)"}.sorted()
        let s=spaces.map{"\($0.displayToken):\($0.id):\($0.kind.rawValue)"}.sorted()
        return (d+s).joined(separator:"|")
    }
    public static func diagnostics(spaces: ReadOnlySpaces, trusted: Bool? = nil) -> [String: Any] {
        let info=NSDictionary(contentsOfFile:"/System/Library/CoreServices/SystemVersion.plist") as? [String:Any] ?? [:]
        let displays=displays()
        let controlGranted=trusted ?? AXIsProcessTrusted()
        var result: [String:Any] = [
            "timestamp":ISO8601DateFormatter().string(from:Date()),
            "productVersion":info["ProductVersion"] ?? "unknown", "build":info["ProductBuildVersion"] ?? "unknown",
            "architecture":"arm64", "accessibilityTrusted":controlGranted,
            "authorizationIdentity":AuthorizationIdentity.evidence(trusted:controlGranted),
            "separateSpaces":NSScreen.screensHaveSeparateSpaces,
            "privateSymbols":spaces.evidence(),"bridgedOperationSelectors":spaces.operationSelectors(),"bridgedOperationRuntime":spaces.operationRuntime(),
            "crossSpaceMutation":"UNTESTED / disabled", "coordinateMutation":"UNTESTED / permission gated",
            "diagnosticScope":"Read-only pass; mutation counters describe this pass only",
            "permissionPromptIssued":false, "windowMutationsPerformed":0,
            "windowManagerRunning":NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.WindowManager").count > 0,
            "displays":displays.map{["runtimeToken":$0.token,"name":$0.name,"logicalRole":$0.role.rawValue,"visibleAXFrame":["x":$0.visible.x,"y":$0.visible.y,"width":$0.visible.width,"height":$0.visible.height]]}
        ]
        do {
            let found=try spaces.spaces(displays:displays)
            result["spacesReadStatus"]="PASS (read only)"
            result["spaces"]=found.map{["runtimeID":$0.id,"displayToken":$0.displayToken,"kind":$0.kind.rawValue,"active":$0.active]}
        } catch { result["spacesReadStatus"]="UNAVAILABLE: \(error)" }
        let raw=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        // No names, titles, screenshots, or user document content are exported.
        result["publicWindowCount"]=raw.filter{($0[kCGWindowLayer as String] as? NSNumber)?.intValue==0}.count
        if let own=raw.first(where:{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==getpid()}), let id=own[kCGWindowNumber as String] as? NSNumber {
            do { let ids=try spaces.membership(windowID:id.uint32Value); result["ownWindowMembership"]=ids; result["ownWindowMembershipStatus"]=ids.isEmpty ? "INCONCLUSIVE: no membership for sampled own element" : "PASS (read only)" }
            catch { result["ownWindowMembershipStatus"]="UNAVAILABLE: \(error)" }
        }
        return result
    }
    public static func json(_ value: Any) -> String { String(data:(try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])) ?? Data(),encoding:.utf8) ?? "JSON error" }
}
