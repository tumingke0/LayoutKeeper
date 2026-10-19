// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// 「外接屏在上方 / 右边 / 下方 / 左边」 picked in LayoutKeeper: edge + alignment → origins. Sample identifiers only.
final class QuickArrangementTests: XCTestCase {
    func mac(w: Int = 1512,h: Int = 982,main: Bool = true,x: Int = 0,y: Int = 0) -> LiveDisplay {
        LiveDisplay(id:1,key:"builtin",uuid:"AAAA-BUILTIN",name:"Built-in",builtIn:true,isMain:main,x:x,y:y,width:w,height:h)
    }
    func ext(_ x: Int,_ y: Int,w: Int = 1920,h: Int = 1080,main: Bool = false,id: UInt32 = 2,key: String = "monitor-100-200-300") -> LiveDisplay {
        LiveDisplay(id:id,key:key,uuid:"EXT-\(id)",name:"Monitor",builtIn:false,isMain:main,x:x,y:y,width:w,height:h)
    }
    func targets(_ live: [LiveDisplay],_ edge: ArrangementEdge,_ anchor: ArrangementAnchor,file: StaticString = #filePath,line: UInt = #line) -> ArrangementPlan? {
        guard case .success(let p)=ArrangementGeometry.quickPreset(live,edge:edge,anchor:anchor,id:"q",at:Date(timeIntervalSince1970:0)) else { XCTFail("quickPreset failed",file:file,line:line); return nil }
        guard case .success(let plan)=ArrangementGeometry.plan(p,live) else { XCTFail("plan failed",file:file,line:line); return nil }
        return plan
    }
    func origins(_ plan: ArrangementPlan?) -> [UInt32:[Int]] { Dictionary(uniqueKeysWithValues:(plan?.targets ?? []).map{ ($0.id,[$0.x,$0.y]) }) }
    /// Apply a plan to the live list (what WindowServer would do with a valid target).
    func moved(_ live: [LiveDisplay],_ plan: ArrangementPlan) -> [LiveDisplay] {
        live.map { d in var c=d; if let t=plan.targets.first(where:{ $0.id==d.id }) { c.x=t.x; c.y=t.y }; return c }
    }

    /// Every edge × alignment, MacBook 1512x982 main, monitor 1920x1080 (starting centred above, the home setup).
    func testAllEdgesAndAlignments() {
        let live=[mac(),ext(-204,-1080)]
        let expected: [ArrangementEdge:[ArrangementAnchor:[Int]]]=[
            .above:[.start:[0,-1080],.center:[-204,-1080],.end:[-408,-1080]],
            .below:[.start:[0,982],.center:[-204,982],.end:[-408,982]],
            .right:[.start:[1512,0],.center:[1512,-49],.end:[1512,-98]],
            .left:[.start:[-1920,0],.center:[-1920,-49],.end:[-1920,-98]],
        ]
        for edge in ArrangementGeometry.quickEdges { for anchor in [ArrangementAnchor.start,.center,.end] {
            let plan=targets(live,edge,anchor)
            XCTAssertEqual(origins(plan)[1],[0,0],"main stays \(edge)/\(anchor)")
            XCTAssertEqual(origins(plan)[2],expected[edge]![anchor]!,"\(edge)/\(anchor)")
            guard let plan else { continue }
            XCTAssertEqual(plan.alreadyApplied,edge == .above && anchor == .center)
            XCTAssertFalse(plan.resolved)
            let after=moved(live,plan)
            XCTAssertTrue(ArrangementGeometry.valid(after.map(\.rect)),"adjacent, no overlap \(edge)/\(anchor)")
            XCTAssertEqual(ArrangementGeometry.currentEdge(after),edge)
            XCTAssertEqual(ArrangementGeometry.currentAnchor(after),anchor,"\(edge)/\(anchor)")
            // Applying the same choice again is a no-op.
            XCTAssertEqual(targets(after,edge,anchor)?.alreadyApplied,true)
        } }
    }

    func testSmallerMonitorAndOddDifference() {
        // 1280x720 monitor: centred above = (116,-720); right, centred = (1512,131).
        let small=[mac(),ext(1512,0,w:1280,h:720)]
        XCTAssertEqual(origins(targets(small,.above,.center))[2],[116,-720])
        XCTAssertEqual(origins(targets(small,.right,.center))[2],[1512,131])
        XCTAssertEqual(origins(targets(small,.below,.end))[2],[232,982])
        XCTAssertEqual(origins(targets(small,.left,.end))[2],[-1280,262])
        // Odd difference rounds down: (1512-1921)/2 = -204.5 → -205.
        XCTAssertEqual(origins(targets([mac(),ext(1512,0,w:1921)],.above,.center))[2],[-205,-1080])
    }

    func testExternalMainMovesTheMacBook() {
        // The monitor is main (menu bar on it): it stays at (0,0), the MacBook screen moves to the opposite side.
        let live=[mac(main:false,x:-1512,y:0),ext(0,0,main:true)]
        XCTAssertEqual(origins(targets(live,.above,.center)),[2:[0,0],1:[204,1080]])
        XCTAssertEqual(origins(targets(live,.right,.start)),[2:[0,0],1:[-1512,0]])
        XCTAssertEqual(origins(targets(live,.left,.end)),[2:[0,0],1:[1920,98]])
        XCTAssertEqual(origins(targets(live,.below,.start)),[2:[0,0],1:[0,-982]])
        let plan=targets(live,.above,.center)!
        let after=moved(live,plan)
        XCTAssertTrue(ArrangementGeometry.valid(after.map(\.rect)))
        // Edge is always the monitor's side of the MacBook screen, whichever is main.
        XCTAssertEqual(ArrangementGeometry.currentEdge(after),.above)
        XCTAssertEqual(ArrangementGeometry.currentAnchor(after),.center)
        // Started with the monitor right of the MacBook, top edges aligned: choosing exactly that is a no-op.
        XCTAssertEqual(ArrangementGeometry.currentEdge(live),.right)
        XCTAssertEqual(targets(live,.right,.start)?.alreadyApplied,true)
        XCTAssertEqual(targets(live,.left,.start)?.alreadyApplied,false)
    }

    func testCurrentEdgeAnyAlignmentAndEqualSizes() {
        // An offset that is none of the three alignments: the edge still counts (✓), the alignment doesn't.
        let off=[mac(),ext(1512,300)]
        XCTAssertEqual(ArrangementGeometry.currentEdge(off),.right)
        XCTAssertNil(ArrangementGeometry.currentAnchor(off))
        // Same height beside: all three alignments are the same place → centred.
        let same=[mac(),ext(1512,0,w:1512,h:982)]
        XCTAssertEqual(ArrangementGeometry.currentAnchor(same),.center)
        XCTAssertEqual(targets(same,.right,.start)?.alreadyApplied,true)
        XCTAssertEqual(targets(same,.right,.end)?.alreadyApplied,true)
        // Corner only: no edge.
        XCTAssertNil(ArrangementGeometry.currentEdge([mac(),ext(1512,982)]))
    }

    func testPresetFromQuickChoice() {
        guard case .success(let p)=ArrangementGeometry.quickPreset([mac(),ext(-204,-1080)],edge:.right,anchor:.end,id:"x",at:Date()) else { return XCTFail() }
        XCTAssertEqual(p.name,"外接屏在右边（靠下）")
        XCTAssertEqual(p.displays.map(\.key),["builtin","monitor-100-200-300"])
        XCTAssertEqual(p.displays[1].relation,ArrangementRelation(parent:"builtin",edge:.right,anchor:.end,offset:0))
        XCTAssertEqual(ArrangementGeometry.describe(p),"Monitor 在 MacBook 屏幕右边，底边对齐")
        // Equal sizes: the chosen alignment is kept (not capture's tie-break).
        guard case .success(let c)=ArrangementGeometry.quickPreset([mac(),ext(0,-982,w:1512,h:982)],edge:.below,anchor:.center,id:"y",at:Date()) else { return XCTFail() }
        XCTAssertEqual(c.displays[1].relation?.anchor,.center)
        XCTAssertEqual(c.name,"外接屏在下方")
        // A saved quick preset still works after a resolution change (re-solved from the relation).
        var bigger=ext(-204,-1080); bigger.width=2560; bigger.height=1440
        guard case .success(let plan)=ArrangementGeometry.plan(p,[mac(),bigger]) else { return XCTFail() }
        XCTAssertTrue(plan.resolved)
        XCTAssertEqual(origins(plan)[2],[1512,982-1440])
    }

    func testNotAPair() {
        func issue(_ live: [LiveDisplay]) -> ArrangementIssue? {
            if case .failure(let e)=ArrangementGeometry.quickPreset(live,edge:.above,anchor:.center,id:"",at:Date()) { return e }
            return nil
        }
        XCTAssertEqual(issue([mac()]),.singleDisplay)
        XCTAssertEqual(issue([ext(0,0,main:true),ext(1920,0,id:3,key:"monitor-1-2-3")]),.notPair)
        XCTAssertEqual(issue([mac(),ext(1512,0),ext(3432,0,id:3,key:"monitor-1-2-3")]),.notPair)
        var m=ext(0,0); m.mirrored=true
        XCTAssertEqual(issue([mac(),m]),.mirroring)
        XCTAssertNil(ArrangementGeometry.currentEdge([mac(),ext(1512,0),ext(3432,0,id:3,key:"monitor-1-2-3")]))
    }

    func testMenuQuickItems() {
        let menu=ArrangementMenu.build(presets:[],live:[mac(),ext(-204,-1080)],busy:nil,hotkeysEnabled:true)!
        XCTAssertEqual(menu.quick.map(\.edge),[.above,.right,.below,.left])
        XCTAssertEqual(menu.quick.map(\.active),[true,false,false,false])
        XCTAssertNil(menu.quickBlock)
        let items=StatusMenuModel.arrangementMenu(menu).children
        XCTAssertEqual(items.prefix(4).map(\.id),["arrange.q.above","arrange.q.right","arrange.q.below","arrange.q.left"])
        XCTAssertEqual(items.prefix(4).map(\.title),["外接屏在上方","外接屏在右边","外接屏在下方","外接屏在左边"])
        XCTAssertEqual(items.prefix(4).map(\.checked),[true,false,false,false])
        XCTAssertFalse(items.contains{ $0.id=="arrange.none" })
        // Right, any alignment → ✓ on 右边.
        XCTAssertEqual(ArrangementMenu.build(presets:[],live:[mac(),ext(1512,300)],busy:nil,hotkeysEnabled:true)!.quick.map(\.active),[false,true,false,false])
        // Two monitors: listed but disabled with the reason; busy disables too.
        let two=ArrangementMenu.build(presets:[],live:[mac(),ext(1512,0),ext(3432,0,id:3,key:"monitor-1-2-3")],busy:nil,hotkeysEnabled:true)!
        XCTAssertEqual(two.quickBlock,ArrangementIssue.notPair.message)
        XCTAssertTrue(StatusMenuModel.arrangementMenu(two).children.prefix(4).allSatisfy{ !$0.enabled && $0.reason==ArrangementIssue.notPair.message })
        let busy=ArrangementMenu.build(presets:[],live:[mac(),ext(-204,-1080)],busy:"wait",hotkeysEnabled:true)!
        XCTAssertTrue(StatusMenuModel.arrangementMenu(busy).children.prefix(4).allSatisfy{ !$0.enabled && $0.reason=="wait" })
    }

    func testLabels() {
        XCTAssertEqual(ArrangementGeometry.quickEdges.map(ArrangementGeometry.edgeLabel),["上方","右边","下方","左边"])
        XCTAssertEqual([ArrangementAnchor.start,.center,.end].map{ ArrangementGeometry.alignmentLabel(edge:.above,anchor:$0) },["靠左","居中","靠右"])
        XCTAssertEqual([ArrangementAnchor.start,.center,.end].map{ ArrangementGeometry.alignmentLabel(edge:.left,anchor:$0) },["靠上","居中","靠下"])
        XCTAssertEqual(ArrangementGeometry.quickName(edge:.below,anchor:.start),"外接屏在下方（靠左）")
    }
}
