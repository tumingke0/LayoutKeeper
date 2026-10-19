// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public struct Rect: Codable, Equatable, Hashable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public func near(_ other: Rect, tolerance: Double = 3) -> Bool {
        zip([x,y,width,height], [other.x,other.y,other.width,other.height]).allSatisfy { abs($0-$1) <= tolerance }
    }
    public func normalized(in bounds: Rect) -> Rect { Rect((x-bounds.x)/bounds.width,(y-bounds.y)/bounds.height,width/bounds.width,height/bounds.height) }
    public func fitted(in bounds: Rect) -> Rect {
        let w = min(width * bounds.width, bounds.width), h = min(height * bounds.height, bounds.height)
        return Rect(bounds.x + min(max(x * bounds.width,0),bounds.width-w), bounds.y + min(max(y * bounds.height,0),bounds.height-h),w,h)
    }
}
public enum DisplayRole: String, Codable, CaseIterable { case builtIn, external }
public enum SpaceKind: String, Codable { case ordinary, fullScreenOrSplit, unknown }
public struct Display: Codable, Equatable {
    public var token: String; public var name: String; public var role: DisplayRole; public var visible: Rect
    public init(token: String, name: String, role: DisplayRole, visible: Rect) { self.token=token; self.name=name; self.role=role; self.visible=visible }
}
public struct Space: Codable, Equatable {
    public var id: UInt64; public var displayToken: String; public var kind: SpaceKind; public var active: Bool
    /// The desktop's "uuid" from the managed-spaces table, when macOS reports one. Like the ManagedSpaceID it
    /// survives unplug/replug (macOS carries the desktop to the built-in screen and back); it is the stronger of the
    /// two identities because IDs are reused after a logout while uuids are not. Optional: older snapshots lack it.
    public var uuid: String? = nil
    public init(id: UInt64, displayToken: String, kind: SpaceKind = .ordinary, active: Bool = false, uuid: String? = nil) { self.id=id; self.displayToken=displayToken; self.kind=kind; self.active=active; self.uuid=uuid }
}
public struct WindowSelector: Codable, Equatable, Hashable {
    public var bundleID: String; public var document: String?; public var title: String
    public init(bundleID: String, document: String? = nil, title: String) { self.bundleID=bundleID; self.document=document; self.title=title }
    public var usable: Bool { !bundleID.isEmpty && (!(document ?? "").isEmpty || !title.isEmpty) }
    public func matches(_ other: WindowSelector) -> Bool {
        guard bundleID == other.bundleID else { return false }
        if let document, !document.isEmpty { return document == other.document }
        return !title.isEmpty && title == other.title
    }
}
public struct ObservedWindow: Codable, Equatable {
    public var token: String; public var selector: WindowSelector; public var frame: Rect; public var spaceIDs: [UInt64]
    public var ordinary: Bool; public var minimized: Bool; public var fullScreen: Bool
    public var processStartedAt: Date?
    public init(token: String, selector: WindowSelector, frame: Rect, spaceIDs: [UInt64], ordinary: Bool = true, minimized: Bool = false, fullScreen: Bool = false, processStartedAt: Date? = nil) {
        self.token=token; self.selector=selector; self.frame=frame; self.spaceIDs=spaceIDs; self.ordinary=ordinary; self.minimized=minimized; self.fullScreen=fullScreen; self.processStartedAt=processStartedAt
    }
}
// Window tokens are scoped to the running observer and never go into a saved profile. Desk (Space) IDs and uuids do
// since 0.6.9 (`SavedWindow.desktopID`): macOS keeps them when the monitor is unplugged and plugged back in.
public struct Snapshot: Codable {
    public var session: UUID; public var topology: String; public var displays: [Display]; public var spaces: [Space]; public var windows: [ObservedWindow]
    public init(session: UUID, topology: String, displays: [Display], spaces: [Space], windows: [ObservedWindow]) { self.session=session; self.topology=topology; self.displays=displays; self.spaces=spaces; self.windows=windows }
}
public struct SavedWindow: Codable, Equatable {
    public var selector: WindowSelector; public var displayRole: DisplayRole; public var desktopLabel: String; public var normalizedFrame: Rect
    /// 1-based position of the window's ordinary desktop on its monitor when saved (an ordinal, never a Space ID).
    /// Records saved before 0.2.0 do not have it.
    public var desktopIndex: Int?
    /// Chrome profile folder ("Default", "Profile 2", …) when it could be determined at save time. Display names can
    /// repeat across Google accounts; the folder cannot. Local only, never synced.
    public var browserProfile: String?=nil
    /// The desktop's ManagedSpaceID when saved. macOS keeps a desktop's ID (and uuid) when the monitor is unplugged
    /// and plugged back in, so on restore the window goes back to this exact desktop if it is on the target screen,
    /// regardless of how many desktops were added or removed before it. Absent in records saved before 0.6.9.
    public var desktopID: UInt64?=nil
    /// The desktop's managed-spaces uuid when saved (see `Space.uuid`). Absent before 0.6.9 or when macOS has none.
    public var desktopUUID: String?=nil
    /// Which live window this was when recorded (live record only). Valid only within one app run: the token is
    /// "pid:windowID", and the process start time guards against pid reuse.
    public var runtime: RuntimeWindowIdentity?=nil
    public init(selector: WindowSelector, displayRole: DisplayRole, desktopLabel: String, normalizedFrame: Rect, desktopIndex: Int? = nil, desktopID: UInt64? = nil, desktopUUID: String? = nil) { self.selector=selector; self.displayRole=displayRole; self.desktopLabel=desktopLabel; self.normalizedFrame=normalizedFrame; self.desktopIndex=desktopIndex; self.desktopID=desktopID; self.desktopUUID=desktopUUID }
}
/// A window's identity inside one run of its app: CGWindowID-based token plus the app's launch date. If both match,
/// it is the same window even if its title changed in between.
public struct RuntimeWindowIdentity: Codable, Equatable, Hashable {
    public var token: String; public var processStartedAt: Date?
    public init(token: String, processStartedAt: Date?) { self.token=token; self.processStartedAt=processStartedAt }
    /// Same token and the same process run. A missing launch date on either side never matches: a reused pid
    /// could otherwise inherit an old window's identity.
    public func matches(_ window: ObservedWindow) -> Bool {
        guard token == window.token, let a = processStartedAt, let b = window.processStartedAt else { return false }
        return abs(a.timeIntervalSince(b)) <= 0.5
    }
    /// The CGWindowID part of the token, if it has one.
    public var windowID: UInt32? { token.split(separator: ":").last.flatMap { UInt32($0) } }
}
public struct Profile: Codable, Equatable {
    public var schemaVersion = 1; public var location: String; public var windows: [SavedWindow]
    public init(location: String, windows: [SavedWindow]) { self.location=location; self.windows=windows }
    public func validate() throws {
        guard schemaVersion == 1, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LayoutError.invalidProfile }
        guard windows.allSatisfy({ ($0.selector.usable || $0.runtime != nil) && !$0.desktopLabel.isEmpty && $0.normalizedFrame.valid && $0.normalizedFrame.width <= 4 && $0.normalizedFrame.height <= 4 && ($0.desktopIndex ?? 1) >= 1 && ($0.desktopIndex ?? 1) <= 64 }) else { throw LayoutError.invalidProfile }
    }
}
public struct DesktopBinding: Equatable {
    public var label: String; public var role: DisplayRole; public var spaceID: UInt64; public var session: UUID; public var topology: String
    public init(label: String, role: DisplayRole, spaceID: UInt64, snapshot: Snapshot) { self.label=label; self.role=role; self.spaceID=spaceID; self.session=snapshot.session; self.topology=snapshot.topology }
}
public enum LayoutError: Error { case invalidProfile, unsupported, permissionRequired, readbackUnavailable }
public enum PlanStatus: String, Codable { case ready, blocked, skipped }
public struct PlanEntry: Codable {
    public var saved: SavedWindow; public var status: PlanStatus; public var reason: String
    public var window: ObservedWindow?; public var targetSpace: UInt64?; public var targetDisplay: String?; public var targetFrame: Rect?
    /// The window was chosen by its runtime token (user pick or slot/geometry tie-break), so the executor
    /// checks token uniqueness instead of selector uniqueness. Token + process start time still must match.
    public var tokenPinned: Bool? = nil
    public init(saved: SavedWindow, status: PlanStatus, reason: String, window: ObservedWindow? = nil, targetSpace: UInt64? = nil, targetDisplay: String? = nil, targetFrame: Rect? = nil) { self.saved=saved; self.status=status; self.reason=reason; self.window=window; self.targetSpace=targetSpace; self.targetDisplay=targetDisplay; self.targetFrame=targetFrame }
}
public struct RestorePlan: Codable {
    public var session: UUID; public var topology: String; public var entries: [PlanEntry]
    public init(session: UUID,topology: String,entries: [PlanEntry]) { self.session=session;self.topology=topology;self.entries=entries }
}
public enum Outcome: String, Codable { case verified, failed, blocked, skipped }
public struct RestoreResult: Codable {
    public var title: String; public var outcome: Outcome; public var detail: String; public var observed: ObservedWindow?
    public init(title: String, outcome: Outcome, detail: String, observed: ObservedWindow? = nil) { self.title=title; self.outcome=outcome; self.detail=detail; self.observed=observed }
}
public protocol SpacesBackend: AnyObject {
    var canMove: Bool { get }
    func move(window: ObservedWindow, to space: UInt64) throws
}
/// An error that may go away if the same read is tried again shortly, e.g. an app that did not answer an
/// Accessibility request in time (AXError -25204). Restore retries these reads instead of failing the window.
public protocol TransientFailure: Error { var isTransient: Bool { get } }
public func isTransientFailure(_ error: Error) -> Bool { (error as? TransientFailure)?.isTransient == true }

public protocol WindowBackend: AnyObject {
    func snapshot() throws -> Snapshot
    func setFrame(window: ObservedWindow, to frame: Rect) throws
    func readWindow(token: String) throws -> ObservedWindow?
}
