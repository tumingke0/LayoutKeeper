// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class DisplayArrangementTests: XCTestCase {
    // A 14" MacBook (1512x982 points) and a 1920x1080 monitor; sample identifiers only.
    let bKey="builtin", eKey="monitor-100-200-300"
    func builtIn(_ x: Int = 0,_ y: Int = 0,w: Int = 1512,h: Int = 982,main: Bool = true) -> LiveDisplay {
        LiveDisplay(id:1,key:bKey,uuid:"AAAA-BUILTIN",name:"Built-in",builtIn:true,isMain:main,x:x,y:y,width:w,height:h)
    }
    func external(_ x: Int,_ y: Int,w: Int = 1920,h: Int = 1080,main: Bool = false,uuid: String = "BBBB-EXT",id: UInt32 = 2) -> LiveDisplay {
        LiveDisplay(id:id,key:eKey,uuid:uuid,name:"Monitor",builtIn:false,isMain:main,x:x,y:y,width:w,height:h)
    }
    func capture(_ live: [LiveDisplay]) -> ArrangementPreset {
        guard case .success(let p)=ArrangementGeometry.capture(live,id:"P",name:"n",at:Date(timeIntervalSince1970:0)) else { XCTFail("capture failed"); return ArrangementPreset(id:"",name:"",createdAt:Date(),displays:[]) }
        return p
    }
    func plan(_ p: ArrangementPreset,_ live: [LiveDisplay]) -> ArrangementPlan? {
        guard case .success(let r)=ArrangementGeometry.plan(p,live) else { return nil }
        return r
    }
    func origin(_ plan: ArrangementPlan?,_ id: UInt32) -> [Int]? { plan?.targets.first{ $0.id==id }.map{ [$0.x,$0.y] } }
    func relation(_ p: ArrangementPreset) -> ArrangementRelation? { p.displays.first{ $0.key==eKey }?.relation }

    // MARK: capture: each edge and anchor

    func testCaptureCentredAbove() {
        // The real home setup: monitor centred above the MacBook at (-204,-1080).
        let p=capture([builtIn(),external(-204,-1080)])
        XCTAssertEqual(p.displays.map(\.key),[bKey,eKey])
        XCTAssertNil(p.displays[0].relation)
        XCTAssertEqual(relation(p),ArrangementRelation(parent:bKey,edge:.above,anchor:.center,offset:0))
        XCTAssertEqual(ArrangementGeometry.describe(p),"Monitor 在 MacBook 屏幕上方，居中")
        XCTAssertEqual(ArrangementGeometry.suggestedName(p),"外接屏在上方")
    }
    func testCaptureEachEdgeAndAnchor() {
        XCTAssertEqual(relation(capture([builtIn(),external(1512,982-1080)])),ArrangementRelation(parent:bKey,edge:.right,anchor:.end,offset:0))
        XCTAssertEqual(relation(capture([builtIn(),external(1512,0)])),ArrangementRelation(parent:bKey,edge:.right,anchor:.start,offset:0))
        XCTAssertEqual(relation(capture([builtIn(),external(-1920,-49)])),ArrangementRelation(parent:bKey,edge:.left,anchor:.center,offset:0))
        XCTAssertEqual(relation(capture([builtIn(),external(0,982)])),ArrangementRelation(parent:bKey,edge:.below,anchor:.start,offset:0))
        XCTAssertEqual(relation(capture([builtIn(),external(-408,-1080)])),ArrangementRelation(parent:bKey,edge:.above,anchor:.end,offset:0))
        // Not aligned to anything: nearest anchor plus the remaining offset.
        XCTAssertEqual(relation(capture([builtIn(),external(1512,300)])),ArrangementRelation(parent:bKey,edge:.right,anchor:.start,offset:300))
        XCTAssertEqual(relation(capture([builtIn(),external(-150,-1080)])),ArrangementRelation(parent:bKey,edge:.above,anchor:.center,offset:54))
        XCTAssertEqual(ArrangementGeometry.describe(capture([builtIn(),external(1512,300)])),"Monitor 在 MacBook 屏幕右边，顶边对齐，错开 300 点")
    }
    func testCaptureRefusals() {
        XCTAssertEqual(capFail([builtIn()]),.singleDisplay)
        var m=external(1512,0); m.mirrored=true
        XCTAssertEqual(capFail([builtIn(),m]),.mirroring)
        var a=external(1512,0); a.asleep=true
        XCTAssertEqual(capFail([builtIn(),a]),.asleep)
        XCTAssertEqual(capFail([builtIn(main:false),external(1512,0)]),.noMain)
        // Only touching at a corner: macOS itself would move it, so it is not an arrangement we can describe.
        XCTAssertEqual(capFail([builtIn(),external(1512,982)]),.notAdjacent)
    }
    func capFail(_ live: [LiveDisplay]) -> ArrangementIssue? {
        if case .failure(let e)=ArrangementGeometry.capture(live,id:"x",name:"",at:Date()) { return e }
        return nil
    }

    // MARK: plan

    func testRoundTripIsIdentityAndNoFlicker() {
        for ext in [external(-204,-1080),external(1512,-98),external(-1920,300),external(-37,982)] {
            let live=[builtIn(),ext]
            let p=plan(capture(live),live)!
            XCTAssertTrue(p.alreadyApplied,"\(ext)")
            XCTAssertFalse(p.resolved)
            XCTAssertEqual(origin(p,1),[0,0]); XCTAssertEqual(origin(p,2),[ext.x,ext.y])
        }
    }
    func testSwitchRightToAboveAndBack() {
        let right=capture([builtIn(),external(1512,-98)]), above=capture([builtIn(),external(-204,-1080)])
        let toAbove=plan(above,[builtIn(),external(1512,-98)])!
        XCTAssertFalse(toAbove.alreadyApplied)
        XCTAssertEqual(origin(toAbove,1),[0,0]); XCTAssertEqual(origin(toAbove,2),[-204,-1080])
        // Every display gets an origin in the transaction, the main one included.
        XCTAssertEqual(Set(toAbove.targets.map(\.id)),[1,2])
        let toRight=plan(right,[builtIn(),external(-204,-1080)])!
        XCTAssertEqual(origin(toRight,2),[1512,-98])
    }
    func testResolutionChangeKeepsRelation() {
        let right=capture([builtIn(),external(1512,982-1080)])          // bottom edges aligned
        let p=plan(right,[builtIn(),external(-204,-1440,w:2560,h:1440)])!
        XCTAssertTrue(p.resolved)
        XCTAssertEqual(origin(p,2),[1512,982-1440])                     // still flush right, bottoms still aligned
        let above=capture([builtIn(),external(-204,-1080)])            // centred
        XCTAssertEqual(origin(plan(above,[builtIn(),external(1512,0,w:2560,h:1440)]),2),[-524,-1440])
        // The MacBook's own scaling changed (1512 → 1800 wide): the monitor moves with the new edge.
        XCTAssertEqual(origin(plan(right,[builtIn(w:1800,h:1169),external(1800,0)]),2),[1800,1169-1080])
        XCTAssertEqual(origin(plan(above,[builtIn(w:1800,h:1169),external(1800,0)]),2),[-60,-1080])
    }
    func testRotatedMonitorIsResolved() {
        let right=capture([builtIn(),external(1512,0)])               // top edges aligned
        let p=plan(right,[builtIn(),external(1512,0,w:1080,h:1920)])!
        XCTAssertTrue(p.resolved); XCTAssertEqual(origin(p,2),[1512,0])
    }
    func testOffsetIsClampedToKeepASharedEdge() {
        let r=ArrangementRelation(parent:bKey,edge:.right,anchor:.start,offset:2000)
        let rect=ArrangementGeometry.place(width:1920,height:1080,against:IntRect(x:0,y:0,width:1512,height:982),r)
        XCTAssertEqual([rect.x,rect.y],[1512,982-ArrangementGeometry.minimumSharedEdge])
        let l=ArrangementRelation(parent:bKey,edge:.above,anchor:.end,offset:-5000)
        let r2=ArrangementGeometry.place(width:1920,height:1080,against:IntRect(x:0,y:0,width:1512,height:982),l)
        XCTAssertEqual([r2.x,r2.y],[-1920+ArrangementGeometry.minimumSharedEdge,-1080])
        // A display shorter than the minimum keeps its whole length on the edge.
        let tiny=ArrangementGeometry.place(width:40,height:40,against:IntRect(x:0,y:0,width:1512,height:982),ArrangementRelation(parent:bKey,edge:.below,anchor:.start,offset:-500))
        XCTAssertEqual([tiny.x,tiny.y],[0,982])
    }
    func testMainDisplayStaysWhereItIs() {
        // Saved with the MacBook as main; now the monitor is main (menu bar on it). The main display must not change:
        // the whole layout is translated so the monitor stays at (0,0).
        let right=capture([builtIn(),external(1512,-98)])
        let live=[builtIn(-204,1080,main:false),external(0,0,main:true)]
        let p=plan(right,live)!
        XCTAssertEqual(origin(p,2),[0,0]); XCTAssertEqual(origin(p,1),[-1512,98])
        // …and a preset saved with the monitor as main applies the same way while the MacBook is main.
        let saved=capture([builtIn(-1512,98,main:false),external(0,0,main:true)])
        XCTAssertEqual(saved.displays.first?.key,eKey)
        XCTAssertEqual(ArrangementGeometry.suggestedName(saved),"MacBook 在左边")
        XCTAssertEqual(ArrangementGeometry.describe(saved),"MacBook 屏幕 在 Monitor 左边，底边对齐")
        let back=plan(saved,[builtIn(),external(-204,-1080)])!
        XCTAssertEqual(origin(back,1),[0,0]); XCTAssertEqual(origin(back,2),[1512,-98])
        XCTAssertTrue(ArrangementGeometry.sameArrangement(right,saved))
    }

    // MARK: matching

    func testMatchesByUUIDThenByMonitorKey() {
        let p=capture([builtIn(),external(1512,-98)])
        // Same monitor in another port: the UUID differs, the vendor/model/serial key still matches.
        let moved=[builtIn(),external(-204,-1080,uuid:"CCCC-OTHER-PORT")]
        XCTAssertEqual(origin(plan(p,moved),2),[1512,-98])
        XCTAssertEqual(issue(p,[builtIn()]),.missing(["Monitor"]))
        var other=external(1512,0); other.key="monitor-9-9-9"; other.name="Other"; other.uuid="DDDD"
        XCTAssertEqual(issue(p,[builtIn(),other]),.missing(["Monitor"]))
        XCTAssertEqual(issue(p,[builtIn(),external(1512,0),{ var t=other; t.id=3; t.x = -1920; return t }()]),.extra(["Other"]))
        // Lid closed (clamshell): the MacBook screen is off, never re-arrange then.
        XCTAssertEqual(issue(p,[external(0,0,main:true)]),.builtInOff)
        XCTAssertEqual(ArrangementGeometry.status(p,[external(0,0,main:true)]),.blocked(.builtInOff))
        var mirrored=[builtIn(),external(0,0)]; mirrored[1].mirrored=true
        XCTAssertEqual(issue(p,mirrored),.mirroring)
        XCTAssertEqual(ArrangementGeometry.status(p,mirrored),.blocked(.mirroring))
        XCTAssertEqual(ArrangementGeometry.status(p,[builtIn(),external(1512,-98)]),.applicable(active:true))
        XCTAssertEqual(ArrangementGeometry.status(p,[builtIn(),external(-204,-1080)]),.applicable(active:false))
        if case .otherDisplays=ArrangementGeometry.status(p,[builtIn(),other]) {} else { XCTFail() }
    }
    func issue(_ p: ArrangementPreset,_ live: [LiveDisplay]) -> ArrangementIssue? {
        if case .failure(let e)=ArrangementGeometry.plan(p,live) { return e }
        return nil
    }
    func testTwinMonitorsWithoutSerialAreToldApartByUUID() {
        var a=external(1512,0,uuid:"T-1",id:2), b=external(3432,0,uuid:"T-2",id:3)
        a.key="monitor-5-6-0"; b.key="monitor-5-6-0"
        let p=capture([builtIn(),a,b])
        XCTAssertEqual(Set(p.displays.map(\.key)).count,3)
        XCTAssertTrue(plan(p,[builtIn(),a,b])!.alreadyApplied)
        // Swapped on the desk: each UUID goes back to its own place.
        let swapped=plan(p,[builtIn(),{ var t=a; t.x=3432; return t }(),{ var t=b; t.x=1512; return t }()])!
        XCTAssertEqual(origin(swapped,2),[1512,0]); XCTAssertEqual(origin(swapped,3),[3432,0])
        // Both UUIDs changed: the key alone can't tell them apart, so nothing is guessed.
        XCTAssertEqual(issue(p,[builtIn(),{ var t=a; t.uuid="N1"; return t }(),{ var t=b; t.uuid="N2"; return t }()]),.ambiguous("Monitor"))
    }

    // MARK: three displays, validation

    func testThreeDisplaysChainAndOverlapAfterResize() {
        // B touches only A (right of A, which sits above the MacBook): B's parent is A.
        let A=external(-204,-1080,uuid:"A",id:2)
        var B=external(1716,-1080,uuid:"B",id:3); B.key="monitor-7-7-7"
        let p=capture([builtIn(),A,B])
        XCTAssertEqual(p.displays.last?.relation,ArrangementRelation(parent:eKey,edge:.right,anchor:.start,offset:0))
        XCTAssertTrue(plan(p,[builtIn(),A,B])!.alreadyApplied)
        // A gets wider: B follows A's right edge.
        let wide=plan(p,[builtIn(),external(0,-1440,w:2560,h:1440,uuid:"A",id:2),B])!
        XCTAssertEqual(origin(wide,2),[-524,-1440]); XCTAssertEqual(origin(wide,3),[2036,-1440])
        // Re-solving that would overlap is refused rather than handed to WindowServer to shuffle.
        let base=LiveDisplay(id:1,key:bKey,uuid:"M",name:"Built-in",builtIn:true,isMain:true,x:0,y:0,width:1000,height:800)
        let r=LiveDisplay(id:2,key:"monitor-1-1-1",uuid:"R",name:"R",builtIn:false,isMain:false,x:1000,y:0,width:1000,height:800)
        let below=LiveDisplay(id:3,key:"monitor-2-2-2",uuid:"D",name:"D",builtIn:false,isMain:false,x:500,y:800,width:1000,height:800)
        let tricky=capture([base,r,below])
        XCTAssertTrue(plan(tricky,[base,r,below])!.alreadyApplied)
        var tall=r; tall.height=1200
        XCTAssertEqual(issue(tricky,[base,tall,below]),.overlap)
    }
    func testValidity() {
        let m=IntRect(x:0,y:0,width:100,height:100)
        XCTAssertTrue(ArrangementGeometry.valid([m,IntRect(x:100,y:50,width:100,height:100)]))
        XCTAssertFalse(ArrangementGeometry.valid([m,IntRect(x:100,y:100,width:100,height:100)]))  // corner only
        XCTAssertFalse(ArrangementGeometry.valid([m,IntRect(x:101,y:0,width:100,height:100)]))    // gap
        XCTAssertFalse(ArrangementGeometry.valid([m,IntRect(x:99,y:0,width:100,height:100)]))     // overlap
        XCTAssertFalse(ArrangementGeometry.valid([IntRect(x:1,y:0,width:100,height:100),IntRect(x:101,y:0,width:100,height:100)])) // nothing at (0,0)
    }

    // MARK: storage, duplicates, menu

    func testCodableRoundTripAndForwardCompatibleTrigger() throws {
        var p=capture([builtIn(),external(-204,-1080)]); p.hotkey=Hotkey(keyCode:18,modifiers:Hotkey.hyper)
        let data=try JSONEncoder().encode([p])
        XCTAssertEqual(try JSONDecoder().decode([ArrangementPreset].self,from:data),[p])
        var json=try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        json[0]["trigger"]=["port":["display":"x","port":"Port-USB-C@1"]]; json[0].removeValue(forKey:"schemaVersion")
        let future=try JSONDecoder().decode([ArrangementPreset].self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(future[0].trigger,.manual); XCTAssertEqual(future[0].schemaVersion,1)
        json[0].removeValue(forKey:"trigger"); json[0].removeValue(forKey:"hotkey")
        XCTAssertNil(try JSONDecoder().decode([ArrangementPreset].self,from:JSONSerialization.data(withJSONObject:json))[0].hotkey)
    }
    func testDuplicateDetection() {
        let a=capture([builtIn(),external(-204,-1080)])
        XCTAssertTrue(ArrangementGeometry.sameArrangement(a,capture([builtIn(),external(-204,-1080)])))
        XCTAssertFalse(ArrangementGeometry.sameArrangement(a,capture([builtIn(),external(-203,-1080)])))
        XCTAssertFalse(ArrangementGeometry.sameArrangement(a,capture([builtIn(),external(-204,-1440,w:2560,h:1440)])))
    }
    func testMenuListsOnlyPresetsForTheseDisplays() {
        var above=capture([builtIn(),external(-204,-1080)]); above.id="above"; above.name="外接屏在上方"; above.hotkey=Hotkey(keyCode:18,modifiers:Hotkey.hyper)
        var right=capture([builtIn(),external(1512,-98)]); right.id="right"; right.name="外接屏在右边"
        var office=right; office.id="office"; office.name="公司"; office.displays[1].key="monitor-1-2-3"; office.displays[1].uuid="OFFICE"
        let live=[builtIn(),external(-204,-1080)]
        let menu=ArrangementMenu.build(presets:[above,right,office],live:live,busy:nil,hotkeysEnabled:true)!
        XCTAssertEqual(menu.entries.map(\.id),["above","right"])
        XCTAssertEqual(menu.entries.map(\.active),[true,false])
        XCTAssertEqual(menu.otherCount,1); XCTAssertNil(menu.saveBlock)
        var s=MenuState(); s.monitorName="M"; s.arrangement=menu
        let items=StatusMenuModel.build(s)
        let sub=items.first{ $0.id=="arrangement" }!
        XCTAssertEqual(sub.title,"显示器排列")
        XCTAssertEqual(sub.children.map(\.id),["arrange.q.above","arrange.q.right","arrange.q.below","arrange.q.left","arrange.sep.quick",
                                               "arrange.saved","arrange.p.above","arrange.p.right","arrange.other","arrange.sep","arrange.save","arrange.manage"])
        let first=sub.children.first{ $0.id=="arrange.p.above" }!
        XCTAssertTrue(first.checked); XCTAssertEqual(first.shortcutText,"⌃⌥⌘1")
        XCTAssertEqual(items.firstIndex{ $0.id=="arrangement" }!+1,items.firstIndex{ $0.id=="sep1" }!)
        // Busy (a confirmation is open): everything disabled with the reason.
        let busy=ArrangementMenu.build(presets:[above,right],live:live,busy:"正在确认上一次切换",hotkeysEnabled:false)!
        XCTAssertNil(busy.entries[0].hotkey)
        var s2=MenuState(); s2.arrangement=busy
        let sub2=StatusMenuModel.build(s2).first{ $0.id=="arrangement" }!
        XCTAssertTrue(sub2.children.filter{ $0.kind == .action }.allSatisfy{ !$0.enabled || $0.id=="arrange.manage" })
        // One display, no presets: no submenu; one display with presets: listed, save blocked.
        XCTAssertNil(ArrangementMenu.build(presets:[],live:[builtIn()],busy:nil,hotkeysEnabled:true))
        let single=ArrangementMenu.build(presets:[above],live:[builtIn()],busy:nil,hotkeysEnabled:true)!
        XCTAssertEqual(single.entries.count,0); XCTAssertEqual(single.otherCount,1); XCTAssertEqual(single.saveBlock,ArrangementIssue.singleDisplay.message)
        let none=StatusMenuModel.build({ var t=MenuState(); t.arrangement=ArrangementMenu.build(presets:[],live:live,busy:nil,hotkeysEnabled:true); return t }()).first{ $0.id=="arrangement" }!
        // No presets yet: the quick options lead, no 「还没有…」 line.
        XCTAssertEqual(none.children.first?.id,"arrange.q.above")
        XCTAssertFalse(none.children.contains{ $0.id=="arrange.none" })
        XCTAssertTrue(single.quick.isEmpty)
        let singleItems=StatusMenuModel.arrangementMenu(single).children
        XCTAssertEqual(singleItems.first?.id,"arrange.none")
    }

    // MARK: own-change guard, hotkeys

    func testSelfArrangementGuardCoversOnlyTheSameDisplays() {
        var g=SelfArrangementGuard(); let t0=Date(timeIntervalSince1970:1000)
        XCTAssertFalse(g.covers([1,2],at:t0))
        g.begin(displays:[1,2],label:"p")
        XCTAssertTrue(g.covers([1,2],at:t0+60))      // in progress: no time limit
        XCTAssertFalse(g.covers([1],at:t0))          // a display went away meanwhile: a real unplug, not ours
        XCTAssertFalse(g.covers([1,2,3],at:t0))      // one was plugged in: not ours either
        g.end(at:t0)
        XCTAssertTrue(g.covers([1,2],at:t0+SelfArrangementGuard.grace-0.1))
        XCTAssertFalse(g.covers([1,2],at:t0+SelfArrangementGuard.grace))
        g.end(at:t0+100)                              // end without begin changes nothing
        XCTAssertFalse(g.covers([1,2],at:t0+100))
    }
    func testPresetHotkeysNeverStealActionKeysOrEachOther() {
        let k1=Hotkey(keyCode:18,modifiers:Hotkey.hyper), save=Hotkey(keyCode:1,modifiers:Hotkey.hyper)
        var attempted=[String]()
        let r=HotkeyRegistrar.registerPresets([(id:"a",title:"A",key:k1),(id:"b",title:"B",key:k1),(id:"c",title:"C",key:save),(id:"d",title:"D",key:nil),(id:"e",title:"E",key:Hotkey(keyCode:18,modifiers:[.shift]))],
                                              enabled:true,taken:[save:"保存当前布局"]) { id,_ in attempted.append(id); return true }
        XCTAssertEqual(r["a"],.active)
        XCTAssertEqual(r["b"],.conflict("与「A」重复"))
        XCTAssertEqual(r["c"],.conflict("与「保存当前布局」重复"))
        XCTAssertEqual(r["d"],.unset)
        if case .invalid=r["e"] {} else { XCTFail() }
        XCTAssertEqual(attempted,["a"])
        let off=HotkeyRegistrar.registerPresets([(id:"a",title:"A",key:k1)],enabled:false,taken:[:]) { _,_ in XCTFail(); return true }
        XCTAssertEqual(off["a"],.off)
        let refused=HotkeyRegistrar.registerPresets([(id:"a",title:"A",key:k1)],enabled:true,taken:[:]) { _,_ in false }
        if case .conflict=refused["a"] {} else { XCTFail() }
    }
}
