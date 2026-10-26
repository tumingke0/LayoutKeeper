// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import IOKit
import IOKit.pwr_mgt
import CoreGraphics
import LayoutCore

/// DDC/CI on Apple Silicon through IOAVService (DCPAVServiceProxy), resolved dynamically. Written from scratch;
/// the general approach (IOAVService I2C at 0x37/0x51) is the one popularized by MonitorControl (MIT), credited in
/// THIRD_PARTY_NOTICES.md. Intel Macs: not implemented yet (callers fall back to software dimming).
public final class DDCService {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY)
    private static let create: Create?=dlsym(io,"IOAVServiceCreateWithService").map{ unsafeBitCast($0,to:Create.self) }
    private static let write: I2C?=dlsym(io,"IOAVServiceWriteI2C").map{ unsafeBitCast($0,to:I2C.self) }
    private static let read: I2C?=dlsym(io,"IOAVServiceReadI2C").map{ unsafeBitCast($0,to:I2C.self) }
    private let service: CFTypeRef
    private let lock=NSLock()
    private init(_ s: CFTypeRef) { service=s }

    /// External AV services in registry order. Matching to CGDisplays is only trusted when the counts agree.
    public static func externalServices() -> [DDCService] {
        #if arch(arm64)
        guard let create else { return [] }
        var it=io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("DCPAVServiceProxy"),&it)==KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out=[DDCService]()
        while case let s=IOIteratorNext(it),s != 0 {
            defer { IOObjectRelease(s) }
            let loc=IORegistryEntryCreateCFProperty(s,"Location" as CFString,nil,0)?.takeRetainedValue() as? String
            guard loc=="External",let svc=create(nil,s)?.takeRetainedValue() else { continue }
            out.append(DDCService(svc))
        }
        return out
        #else
        return []
        #endif
    }

    /// Reads a VCP feature (3 tries). Blocking (~50–150 ms); call off the main thread.
    public func readVCP(_ code: UInt8) -> (current: Int,max: Int)? {
        guard let w=Self.write,let r=Self.read else { return nil }
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<3 {
            var req=DDCPacket.getVCP(code)
            guard req.withUnsafeMutableBytes({ w(service,0x37,0x51,$0.baseAddress!,UInt32($0.count)) })==kIOReturnSuccess else { usleep(30000); continue }
            usleep(50000)
            var rep=[UInt8](repeating:0,count:12)
            if rep.withUnsafeMutableBytes({ r(service,0x37,0x51,$0.baseAddress!,12) })==kIOReturnSuccess,let v=DDCPacket.parseReply(rep,code:code) { return v }
            usleep(40000)
        }
        return nil
    }
    @discardableResult public func writeVCP(_ code: UInt8,_ value: UInt16) -> Bool {
        guard let w=Self.write else { return false }
        lock.lock(); defer { lock.unlock() }
        var pkt=DDCPacket.setVCP(code,value)
        var ok=false
        for _ in 0..<2 where !ok {   // writes are idempotent; one retry
            ok=pkt.withUnsafeMutableBytes({ w(service,0x37,0x51,$0.baseAddress!,UInt32($0.count)) })==kIOReturnSuccess
            if !ok { usleep(20000) }
        }
        return ok
    }
}

/// Built-in display brightness through DisplayServices (private, dynamically loaded).
public enum BuiltInBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let h=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_LAZY)
    private static let getF: Get?=dlsym(h,"DisplayServicesGetBrightness").map{ unsafeBitCast($0,to:Get.self) }
    private static let setF: Set?=dlsym(h,"DisplayServicesSetBrightness").map{ unsafeBitCast($0,to:Set.self) }
    public static func get(_ id: CGDirectDisplayID) -> Double? { var v: Float = -1; guard let getF,getF(id,&v)==0,v>=0 else { return nil }; return Double(v) }
    @discardableResult public static func set(_ id: CGDirectDisplayID,_ v: Double) -> Bool { setF.map{ $0(id,Float(min(1,max(0,v))))==0 } ?? false }
}

/// Software dimming via the display's gamma table. Never below 10% so the screen stays readable. Restored on quit.
public enum SoftwareDimming {
    public static let floor=0.1
    @discardableResult public static func set(_ id: CGDirectDisplayID,_ v: Double) -> Bool {
        let f=CGGammaValue(floor+(1-floor)*min(1,max(0,v)))
        return CGSetDisplayTransferByFormula(id,0,f,1,0,f,1,0,f,1) == .success
    }
    public static func restoreAll() { CGDisplayRestoreColorSyncSettings() }
}

/// Reads active external DisplayPort transports (`IOPortTransportStateDisplayPort`) from IOKit to identify which
/// built-in physical port (e.g. left/right USB-C or HDMI) a monitor is connected through, plus its raw EDID.
public enum DisplayPortReader {
    public static func activePorts() -> [DisplayPortDescriptor] {
        var it=io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOPortTransportStateDisplayPort"),&it)==KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out=[DisplayPortDescriptor]()
        while case let s=IOIteratorNext(it),s != 0 {
            defer { IOObjectRelease(s) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(s,&propsRef,kCFAllocatorDefault,0)==KERN_SUCCESS,
                  let dict=propsRef?.takeRetainedValue() as? [String:Any] else { continue }
            let active=(dict["Active"] as? Bool) ?? ((dict["Active"] as? NSNumber)?.boolValue ?? false)
            guard active else { continue }
            let builtIn=(dict["ParentBuiltInPortNumber"] as? NSNumber)?.intValue ?? (dict["ParentPortNumber"] as? NSNumber)?.intValue ?? 0
            guard builtIn>0 else { continue }
            let explicitType=(dict["ParentBuiltInPortTypeDescription"] as? String) ?? (dict["ParentPortTypeDescription"] as? String)
            let td=dict["TransportDescription"] as? String
            let meta=dict["Metadata"] as? [String:Any]
            let productID=((dict["ProductID"] as? NSNumber) ?? (meta?["ProductID"] as? NSNumber))?.uint32Value
            let serialNumber=((dict["SerialNumber"] as? NSNumber) ?? (meta?["SerialNumber"] as? NSNumber))?.uint32Value
            let edid=(dict["EDID"] as? Data) ?? (meta?["EDID"] as? Data)
            out.append(DisplayPortDescriptor(
                builtInPortNumber:builtIn,
                portType:DisplayPortDescriptor.normalizePortType(explicit:explicitType,transportDescription:td),
                transportDescription:td,
                productID:productID,
                serialNumber:serialNumber,
                edid:edid
            ))
        }
        return out
    }
}

/// Holds and verifies IOKit power assertions (`PreventUserIdleSystemSleep`, `PreventSystemSleep`,
/// `PreventUserIdleDisplaySleep`) and Cocoa `ProcessInfo` activity tokens so macOS stays awake and keeps background
/// network/CLI tools (such as Codex, SSH, remote desktop) alive across screen lock, display off, battery power,
/// notification wakes, and clamshell mode.
public final class SystemSleepGuard {
    private static let assertionReason="LayoutKeeper Keep Awake" as CFString
    private var idleSystemID: IOPMAssertionID=0
    private var systemSleepID: IOPMAssertionID=0
    private var displaySleepID: IOPMAssertionID=0
    private var activityToken: NSObjectProtocol?
    public private(set) var lastPlan: KeepAwakePlan = .inactive
    public private(set) var lastVerified=true
    public init() {}
    deinit { releaseAll() }

    /// True when the MacBook lid is closed (`IOPMrootDomain` -> `"AppleClamshellState"`).
    public static func clamshellState() -> Bool {
        let root=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root,"AppleClamshellState" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? Bool) ?? false
    }

    /// Reads back the assertion types currently held by `pid` in `powerd` (`IOPMCopyAssertionsByProcess`).
    public static func activeAssertionTypes(pid: pid_t = getpid()) -> Set<String> {
        var dictRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictRef)==kIOReturnSuccess,
              let dict=dictRef?.takeRetainedValue() as? [NSNumber:[[String:Any]]] else { return [] }
        let list=dict[NSNumber(value:pid)] ?? []
        return Set(list.compactMap{ ($0["AssertType"] as? String) ?? ($0["AssertionTrueType"] as? String) })
    }

    /// Declares local user activity once (e.g. on a notification wake so `powerd` promotes the wake to FullWake instead
    /// of entering `Notification Wake Back to Sleep` 20 s later, or in clamshell mode if the external display tries to sleep).
    @discardableResult public func declareUserActivity() -> Bool {
        var id: IOPMAssertionID=0
        return IOPMAssertionDeclareUserActivity(Self.assertionReason,kIOPMUserActiveLocal,&id)==kIOReturnSuccess
    }

    public func releaseAll() {
        if idleSystemID != 0 { IOPMAssertionRelease(idleSystemID); idleSystemID=0 }
        if systemSleepID != 0 { IOPMAssertionRelease(systemSleepID); systemSleepID=0 }
        if displaySleepID != 0 { IOPMAssertionRelease(displaySleepID); displaySleepID=0 }
        if let token=activityToken { ProcessInfo.processInfo.endActivity(token); activityToken=nil }
        lastPlan = .inactive; lastVerified=true
    }

    @discardableResult
    public func apply(mode: KeepAwakeMode) -> (plan: KeepAwakePlan,verified: Bool,activeTypes: Set<String>,clamshell: Bool) {
        let clamshell=Self.clamshellState()
        let plan=KeepAwakePolicy.plan(mode:mode,clamshell:clamshell)
        guard plan.isActive else {
            releaseAll()
            return (plan,true,[],clamshell)
        }
        syncAssertions(to:plan)
        var active=Self.activeAssertionTypes()
        if !KeepAwakePolicy.satisfied(plan:plan,activeAssertionTypes:active) {
            // Self-heal if powerd dropped an assertion across sleep/wake.
            releaseAll()
            syncAssertions(to:plan)
            active=Self.activeAssertionTypes()
        }
        let ok=KeepAwakePolicy.satisfied(plan:plan,activeAssertionTypes:active)
        lastPlan=plan; lastVerified=ok
        return (plan,ok,active,clamshell)
    }

    private func syncAssertions(to plan: KeepAwakePlan) {
        if plan.preventIdleSystemSleep {
            if idleSystemID==0 { _=IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),Self.assertionReason,&idleSystemID) }
        } else if idleSystemID != 0 {
            IOPMAssertionRelease(idleSystemID); idleSystemID=0
        }
        if plan.preventSystemSleep {
            if systemSleepID==0 { _=IOPMAssertionCreateWithName("PreventSystemSleep" as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),Self.assertionReason,&systemSleepID) }
        } else if systemSleepID != 0 {
            IOPMAssertionRelease(systemSleepID); systemSleepID=0
        }
        if plan.preventIdleDisplaySleep {
            if displaySleepID==0 { _=IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,IOPMAssertionLevel(kIOPMAssertionLevelOn),Self.assertionReason,&displaySleepID) }
        } else if displaySleepID != 0 {
            IOPMAssertionRelease(displaySleepID); displaySleepID=0
        }
        if plan != lastPlan || activityToken == nil {
            if let token=activityToken { ProcessInfo.processInfo.endActivity(token); activityToken=nil }
            var opts: ProcessInfo.ActivityOptions=[.idleSystemSleepDisabled,.suddenTerminationDisabled]
            if plan.preventIdleDisplaySleep { opts.insert(.idleDisplaySleepDisabled) }
            activityToken=ProcessInfo.processInfo.beginActivity(options:opts,reason:"LayoutKeeper Keep Awake")
        }
    }
}
