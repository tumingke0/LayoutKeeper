// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import LayoutCore

/// Byte layout of the opaque token accepted by the private `_AXUIElementCreateWithRemoteToken`.
/// Written independently from the publicly described format: 20 bytes, little-endian,
/// pid (Int32) | reserved zero (UInt32) | marker 0x636f636f (UInt32) | element identifier (UInt64).
public enum RemoteElementToken {
    public static let length=20
    public static let marker: UInt32=0x636f_636f
    public static let elementIDOffset=12
    public static func bytes(pid: Int32, elementID: UInt64) -> [UInt8] {
        var out=[UInt8](); out.reserveCapacity(length)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(pid); put(UInt32(0)); put(marker); put(elementID)
        return out
    }
}

public struct RemoteWindowSearch {
    public enum Stop: String { case allFound, timeBudget, elementCap, deadline, unavailable, nothingWanted }
    public var found: [UInt32: AXUIElement]=[:]
    public var unresolved: Set<UInt32>
    public var inspected=0
    public var stop: Stop
}

/// Looks up AX elements for windows the app does not publish through kAXWindows
/// (typically windows on Spaces that are not currently shown).
/// Only accepts elements whose role is AXWindow and whose window ID is one of the wanted IDs;
/// the caller still runs the normal pid / CG ownership validation before using an element.
public final class RemoteWindowLocator {
    private typealias Factory = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private let factory: Factory?
    /// Per-process resume points, kept in memory only for this app run.
    private var resumePoints: [String: UInt64]=[:]
    public var perElementTimeout: Float=0.1

    /// `resolveSymbol: false` simulates a macOS where the private factory does not exist (tests).
    public init(resolveSymbol: Bool = true) {
        if resolveSymbol, let library=dlopen(nil,RTLD_LAZY), let symbol=dlsym(library,"_AXUIElementCreateWithRemoteToken") {
            factory=unsafeBitCast(symbol,to:Factory.self)
        } else { factory=nil }
    }
    public var isAvailable: Bool { factory != nil }

    /// - Parameters:
    ///   - processKey: identifies the process instance (pid + launch time) for the resume point.
    ///   - windowID: resolves an element's CG window ID, nil when unreadable.
    public func search(pid: Int32, processKey: String, wanted: Set<UInt32>, timeBudget: TimeInterval, elementCap: UInt64,
                       deadline: TimeInterval?, windowID: (AXUIElement) -> UInt32?) -> RemoteWindowSearch {
        var result=RemoteWindowSearch(unresolved:wanted,stop:.nothingWanted)
        guard !wanted.isEmpty else { return result }
        guard let factory, pid != getpid(), elementCap > 0 else { result.stop = .unavailable; return result }
        let started=ProcessInfo.processInfo.systemUptime
        let stopAt=min(started+max(0,timeBudget),deadline ?? .infinity)
        var buffer=RemoteElementToken.bytes(pid:pid,elementID:0)
        var sweep=ElementIDSweep(start:resumePoints[processKey] ?? 0,cap:elementCap)
        result.stop = .elementCap
        while let elementID=sweep.next() {
            if result.inspected & 0x3f == 0, ProcessInfo.processInfo.systemUptime >= stopAt {
                result.stop = (deadline.map{$0 <= started+timeBudget} ?? false) ? .deadline : .timeBudget
                resumePoints[processKey]=elementID
                return result
            }
            result.inspected+=1
            withUnsafeBytes(of: elementID.littleEndian) { raw in
                for (offset,byte) in raw.enumerated() { buffer[RemoteElementToken.elementIDOffset+offset]=byte }
            }
            guard let data=CFDataCreate(nil,buffer,buffer.count),
                  let element=factory(data)?.takeRetainedValue() else { continue }
            _=AXUIElementSetMessagingTimeout(element,perElementTimeout)
            guard let id=windowID(element), result.unresolved.contains(id) else { continue }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,kAXRoleAttribute as CFString,&role) == .success,
                  (role as? String)==kAXWindowRole else { continue }
            result.found[id]=element
            result.unresolved.remove(id)
            if result.unresolved.isEmpty {
                result.stop = .allFound
                resumePoints.removeValue(forKey:processKey)
                return result
            }
        }
        resumePoints.removeValue(forKey:processKey)
        return result
    }
}

/// Snapshot of the public window list joined with Space membership and optional WindowServer traits.
public struct CGWindowInventory {
    public var candidates: [CGWindowCandidate]
    public var owners: [UInt32: Set<Int32>]
    public var available: Bool
    public var traitsAvailable: Bool

    /// - Parameter includePIDs: only rows owned by these processes get membership / trait reads (owners are kept for all rows).
    public static func collect(spaces: ReadOnlySpaces, includePIDs: Set<Int32>) -> CGWindowInventory {
        guard let rows=CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else {
            return CGWindowInventory(candidates:[],owners:[:],available:false,traitsAvailable:false)
        }
        var owners=[UInt32: Set<Int32>](), base=[CGWindowCandidate]()
        for row in rows {
            guard let id=(row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid=(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            owners[id,default:[]].insert(pid)
            guard includePIDs.contains(pid), let layer=(row[kCGWindowLayer as String] as? NSNumber)?.intValue else { continue }
            var bounds=Rect(0,0,0,0)
            if let dict=row[kCGWindowBounds as String] as? NSDictionary, let rect=CGRect(dictionaryRepresentation:dict as CFDictionary) {
                bounds=Rect(rect.origin.x,rect.origin.y,rect.width,rect.height)
            }
            let alpha=(row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            base.append(CGWindowCandidate(windowID:id,ownerPID:pid,layer:layer,bounds:bounds,alpha:alpha,spaceIDs:nil,traits:nil))
        }
        let layerZero=base.filter{$0.layer==0}.map(\.windowID)
        let traits=spaces.windowServerTraits(windowIDs:layerZero)
        for index in base.indices where base[index].layer==0 {
            base[index].traits=traits?[base[index].windowID]
            base[index].spaceIDs=try? spaces.membership(windowID:base[index].windowID)
        }
        return CGWindowInventory(candidates:base,owners:owners,available:true,traitsAvailable:traits != nil)
    }
}
