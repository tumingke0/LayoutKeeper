// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
public final class DemoBackend: WindowBackend, SpacesBackend {
    public var state: Snapshot
    public var canMove: Bool { true }
    public var pretendSuccess=false
    public init() {
        let selector=WindowSelector(bundleID:"demo.editor",title:"LayoutKeeper 演示项目")
        state=Snapshot(session:UUID(),topology:"simulated-company",displays:[Display(token:"simulated-panel",name:"内置屏",role:.builtIn,visible:Rect(0,30,1200,770)),Display(token:"simulated-company-monitor",name:"公司外屏",role:.external,visible:Rect(1200,0,1920,1080))],spaces:[Space(id:71,displayToken:"simulated-panel",active:true),Space(id:72,displayToken:"simulated-company-monitor",active:true),Space(id:73,displayToken:"simulated-company-monitor")],windows:[ObservedWindow(token:"simulation-only",selector:selector,frame:Rect(20,60,800,600),spaceIDs:[71])])
    }
    public var profile: Profile { Profile(location:"公司（模拟）",windows:[SavedWindow(selector:state.windows[0].selector,displayRole:.external,desktopLabel:"开发",normalizedFrame:Rect(0.05,0.05,0.8,0.85))]) }
    public func plan() throws -> RestorePlan { try Planner.plan(profile:profile,snapshot:state,bindings:[DesktopBinding(label:"开发",role:.external,spaceID:73,snapshot:state)],canMoveSpaces:true) }
    public func snapshot() throws -> Snapshot { state }
    public func readWindow(token: String) throws -> ObservedWindow? { state.windows.first{$0.token==token} }
    public func setFrame(window: ObservedWindow, to frame: Rect) throws { if !pretendSuccess { state.windows[0].frame=frame } }
    public func move(window: ObservedWindow, to space: UInt64) throws { if !pretendSuccess { state.windows[0].spaceIDs=[space] } }
}
