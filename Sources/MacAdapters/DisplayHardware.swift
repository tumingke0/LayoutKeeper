// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import IOKit
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
