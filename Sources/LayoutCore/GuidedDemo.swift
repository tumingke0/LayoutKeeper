// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// A visible in-app simulation, with no AppKit, AX, or operating-system writes.
public final class GuidedDemoBackend: WindowBackend, SpacesBackend {
    public var state: Snapshot
    public var pretendSuccess=false
    public var canMove: Bool { false }
    public init() {
        state=Snapshot(session:UUID(),topology:"guided-simulation",displays:[Display(token:"demo-display",name:"演示屏幕",role:.builtIn,visible:Rect(0,0,1000,640))],spaces:[Space(id:1,displayToken:"demo-display",active:true)],windows:[
            ObservedWindow(token:"editor",selector:WindowSelector(bundleID:"simulation.editor",title:"编辑器"),frame:Rect(50,60,570,480),spaceIDs:[1]),
            ObservedWindow(token:"chat",selector:WindowSelector(bundleID:"simulation.chat",title:"聊天"),frame:Rect(660,60,290,480),spaceIDs:[1])])
    }
    private var binding: DesktopBinding { DesktopBinding(label:"演示桌面",role:.builtIn,spaceID:1,snapshot:state) }
    public func capture(location: String) throws -> Profile {
        let (profile,issues)=try Planner.capture(location:location,snapshot:state,bindings:[binding])
        guard issues.isEmpty, profile.windows.count==2 else { throw LayoutError.readbackUnavailable }
        return profile
    }
    public func plan(profile: Profile) throws -> RestorePlan { try Planner.plan(profile:profile,snapshot:state,bindings:[binding],canMoveSpaces:false) }
    public func scatter() { state.windows[0].frame=Rect(360,180,570,430); state.windows[1].frame=Rect(40,110,290,380) }
    public func snapshot() throws -> Snapshot { state }
    public func readWindow(token: String) throws -> ObservedWindow? { state.windows.first{$0.token==token} }
    public func setFrame(window: ObservedWindow, to frame: Rect) throws {
        guard let index=state.windows.firstIndex(where:{$0.token==window.token && $0.selector==window.selector}) else { throw LayoutError.readbackUnavailable }
        if !pretendSuccess { state.windows[index].frame=frame }
    }
    public func move(window: ObservedWindow, to space: UInt64) throws { throw LayoutError.unsupported }
}
