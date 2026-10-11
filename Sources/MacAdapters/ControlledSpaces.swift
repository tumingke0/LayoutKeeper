// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import ApplicationServices
import LayoutCore

public struct WindowOwnershipClaim {
    public var token: String
    public var axPID: Int32
    public var cgPID: Int32
    public var windowID: UInt32
    public var processStartedAt: Date
    public var bundleID: String
    public init(token: String,axPID: Int32,cgPID: Int32,windowID: UInt32,processStartedAt: Date,bundleID: String) {
        self.token=token;self.axPID=axPID;self.cgPID=cgPID;self.windowID=windowID;self.processStartedAt=processStartedAt;self.bundleID=bundleID
    }
}
public struct SpaceMovePermit {
    public var window: ObservedWindow
    public var session: UUID
    public var topology: String
    public var sourceSpace: UInt64
    public var sourceDisplay: String
    public var targetSpace: UInt64
    public var targetDisplay: String
    /// Window chosen by runtime token (user pick / tie-break): require token uniqueness instead of selector uniqueness.
    public var tokenPinned=false
    public init(window: ObservedWindow,targetSpace: UInt64,targetDisplay: String,snapshot: Snapshot,tokenPinned: Bool = false) throws {
        guard MoveScope.problem(window:window,targetSpace:targetSpace,targetDisplay:targetDisplay,snapshot:snapshot)==nil,
              window.spaceIDs.count==1,window.processStartedAt != nil,let source=snapshot.spaces.first(where:{$0.id==window.spaceIDs[0] && $0.kind == .ordinary}),
              snapshot.spaces.contains(where:{$0.id==targetSpace && $0.kind == .ordinary && $0.displayToken==targetDisplay}) else { throw LayoutError.readbackUnavailable }
        self.window=window;session=snapshot.session;topology=snapshot.topology;sourceSpace=source.id;sourceDisplay=source.displayToken;self.targetSpace=targetSpace;self.targetDisplay=targetDisplay;self.tokenPinned=tokenPinned
    }
}
public struct ResolvedSpaceMove {
    public var source: UInt64
    public var target: UInt64
    public var sourceDisplay: String
    public var targetDisplay: String
}
public enum ControlledSpaceGate {
    public static func resolve(window: ObservedWindow,to space: UInt64,permit: SpaceMovePermit,snapshot: Snapshot,claim: WindowOwnershipClaim) throws -> ResolvedSpaceMove {
        let parts=window.token.split(separator:":")
        guard parts.count==2,let pid=Int32(parts[0]),pid>0,let id=UInt32(parts[1]),id>0,
              claim.token==window.token,claim.axPID==pid,claim.cgPID==pid,claim.windowID==id,
              claim.bundleID==window.selector.bundleID,claim.processStartedAt==window.processStartedAt,
              window.token==permit.window.token,window.selector==permit.window.selector,window.processStartedAt==permit.window.processStartedAt,
              snapshot.session==permit.session,snapshot.topology==permit.topology,
              window.ordinary,!window.fullScreen,!window.minimized,window.frame.valid,window.spaceIDs.count==1,
              (permit.tokenPinned ? snapshot.windows.filter({$0.token==window.token}).count==1 : snapshot.windows.filter({permit.window.selector.matches($0.selector)}).count==1),
              let current=snapshot.windows.first(where:{$0.token==window.token}),current.selector==window.selector,current.processStartedAt==window.processStartedAt,current.spaceIDs==window.spaceIDs,current.frame.near(window.frame,tolerance:0.01),
              snapshot.spaces.contains(where:{$0.id==permit.sourceSpace && $0.kind == .ordinary && $0.displayToken==permit.sourceDisplay}),
              snapshot.spaces.contains(where:{$0.id==permit.targetSpace && $0.kind == .ordinary && $0.displayToken==permit.targetDisplay}),
              snapshot.displays.contains(where:{$0.token==permit.sourceDisplay}),snapshot.displays.contains(where:{$0.token==permit.targetDisplay}) else { throw LayoutError.readbackUnavailable }
        if window.spaceIDs==[permit.sourceSpace],space==permit.targetSpace {
            return ResolvedSpaceMove(source:permit.sourceSpace,target:permit.targetSpace,sourceDisplay:permit.sourceDisplay,targetDisplay:permit.targetDisplay)
        }
        if window.spaceIDs==[permit.targetSpace],space==permit.sourceSpace {
            return ResolvedSpaceMove(source:permit.targetSpace,target:permit.sourceSpace,sourceDisplay:permit.targetDisplay,targetDisplay:permit.sourceDisplay)
        }
        throw LayoutError.unsupported
    }
}

public struct VerifiedAXWindow {
    public let element: AXUIElement
    public let claim: WindowOwnershipClaim
    public let selector: WindowSelector
}
// There is no global enable flag. A mover exists only for the explicitly confirmed preview.
public final class ControlledSpaces: SpacesBackend {
    public let windows: AXWindows
    public let permits: [SpaceMovePermit]
    private let dispatch: (VerifiedAXWindow,ResolvedSpaceMove) throws -> Void
    public var canMove: Bool { windows.writesApproved && !permits.isEmpty }
    public init(windows: AXWindows,permits: [SpaceMovePermit],dispatch: @escaping (VerifiedAXWindow,ResolvedSpaceMove) throws -> Void) {
        self.windows=windows;self.permits=permits;self.dispatch=dispatch
    }
    public func move(window: ObservedWindow,to space: UInt64) throws {
        guard canMove else { throw LayoutError.permissionRequired }
        let matches=permits.filter{$0.window.token==window.token}
        guard matches.count==1 else { throw LayoutError.readbackUnavailable }
        let snapshot=try windows.snapshot()
        let proof=try windows.verifiedMoveWindow(window)
        let request=try ControlledSpaceGate.resolve(window:window,to:space,permit:matches[0],snapshot:snapshot,claim:proof.claim)
        try dispatch(proof,request)
        // Successful dispatch never implies the move happened. ManualRestorer must read membership.
    }
}
