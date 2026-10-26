// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// 0.6.11 desk strip: the T1–T32 scenarios of the design review (desk IDs from the 10/17–10/21 restore logs; titles
/// and profile names are neutral stand-ins). T1–T27 table-driven on `StripMapper`, then whole-path replays.
final class DeskStripTests: XCTestCase {
    // MARK: - Helpers

    /// "1:473·" style spec: (desk id, occupied). uuid "U-<id>" unless given.
    func strip(_ s: [(UInt64,Bool)],uuids: [UInt64:String]=[:],source: DeskStrip.Source = .live) -> DeskStrip {
        DeskStrip(slots:s.map{ StripSlot(desk:DeskRef(id:$0.0,uuid:uuids[$0.0] ?? "U-\($0.0)"),occupied:$0.1) },source:source)
    }
    func spaces(_ ids: [UInt64],_ display: String="ext",uuids: [UInt64:String]=[:]) -> [Space] {
        ids.enumerated().map{ Space(id:$0.element,displayToken:display,active:$0.offset==0,uuid:uuids[$0.element] ?? "U-\($0.element)") }
    }
    /// Maps with `others` = desks that exist elsewhere (built-in screen), besides the current ones.
    func map(_ st: DeskStrip,_ current: [UInt64],others: [UInt64]=[],uuids: [UInt64:String]=[:]) -> StripMapping {
        let cur=spaces(current,uuids:uuids), all=cur+spaces(others,"builtin",uuids:uuids)
        return StripMapper.map(st,current:cur,exists:{ d in all.contains{ d.matches($0) } })
    }
    /// 1-based slots per position (nil = dropped).
    func slots(_ m: StripMapping) -> [Int?] { m.target.map{ $0.map{ $0+1 } } }
    let o=true, e=false

    // MARK: - T1–T27 StripMapper

    /// T1 10/20 home plug: office strip [473·,454·,458●,459●,460●]; home desks; the office desks are on the built-in.
    func testT1HomePlugKeepsPositions() {
        let m=map(strip([(473,e),(454,e),(458,o),(459,o),(460,o)]),[484,446,445,444,443],others:[454,458,459,460])
        XCTAssertEqual(slots(m),[1,2,3,4,5]); XCTAssertEqual(m.needed,5); XCTAssertEqual(m.appended,0)
        XCTAssertTrue(m.alternative.hasPrefix("positional(append=0"),"both plans agree: \(m.alternative)")
    }
    /// T2 other monitor with a single desk: needs 5, 4 appended; once added, as T1.
    func testT2OneDeskNeedsTheWholeStrip() {
        let st=strip([(473,e),(454,e),(458,o),(459,o),(460,o)])
        let m=map(st,[484],others:[454,458,459,460])
        XCTAssertEqual(m.needed,5); XCTAssertEqual(m.appended,4); XCTAssertEqual(slots(m),[1,2,3,4,5])
        XCTAssertEqual(slots(map(st,[484,500,501,502,503],others:[454,458,459,460])),[1,2,3,4,5])
    }
    /// T3 all occupied, other monitor.
    func testT3FullStripOtherMonitor() {
        XCTAssertEqual(map(strip([(440,o),(443,o),(444,o),(445,o),(446,o)]),[454],others:[443,444,445,446]).needed,5)
    }
    /// T4 same monitor, order kept: anchored, nothing but desk 1 changes.
    func testT4SameMonitorOrderKept() {
        let m=map(strip([(416,o),(413,o),(417,o),(418,o),(419,o)]),[440,413,417,418,419])
        XCTAssertEqual(m.kind,.anchored); XCTAssertEqual(slots(m),[1,2,3,4,5]); XCTAssertEqual(m.moves,0); XCTAssertTrue(m.conflicts.isEmpty)
    }
    /// T5 same monitor, macOS gave the desks back reversed (10/20 21:36): positions win, conflicts reported.
    func testT5ReversedDesksGoByPosition() {
        let m=map(strip([(440,o),(443,o),(444,o),(445,o),(446,o)]),[484,446,445,444,443])
        XCTAssertEqual(m.kind,.positional); XCTAssertEqual(slots(m),[1,2,3,4,5]); XCTAssertEqual(m.appended,0)
        XCTAssertEqual(m.conflicts,[2,3,4,5])
    }
    /// T6 partly permuted (10/17 12:06): the strip order is reproduced.
    func testT6PartlyPermuted() {
        let m=map(strip([(251,o),(6,o),(141,o),(254,o),(255,o)]),[259,6,255,254,141])
        XCTAssertEqual(slots(m),[1,2,3,4,5]); XCTAssertEqual(m.appended,0); XCTAssertEqual(m.conflicts,[3,5])
    }
    /// T7 the user deleted an empty middle desk (10/17 15:26): drop it, no desk added, nothing moves.
    func testT7DeletedEmptyMiddleDeskIsDropped() {
        let m=map(strip([(259,o),(6,e),(255,o),(254,o),(141,o)]),[315,255,254,141])
        XCTAssertEqual(m.kind,.anchored); XCTAssertEqual(m.dropped,[2]); XCTAssertEqual(slots(m),[1,nil,2,3,4])
        XCTAssertEqual(m.appended,0); XCTAssertEqual(m.moves,0); XCTAssertEqual(m.needed,4)
    }
    /// T8 the deleted middle desk held windows: positional, one desk appended, conflicts reported.
    func testT8DeletedOccupiedMiddleDeskIsRestored() {
        let m=map(strip([(259,o),(6,o),(255,o),(254,o),(141,o)]),[315,255,254,141])
        XCTAssertEqual(m.kind,.positional); XCTAssertEqual(m.appended,1); XCTAssertEqual(slots(m),[1,2,3,4,5]); XCTAssertFalse(m.conflicts.isEmpty)
        XCTAssertTrue(m.alternative.contains("impossible"))
    }
    /// T9 a deleted trailing empty desk is dropped.
    func testT9DeletedTrailingEmptyDesk() {
        let m=map(strip([(1,o),(2,o),(3,e)]),[90,2])
        XCTAssertEqual(m.dropped,[3]); XCTAssertEqual(m.needed,2); XCTAssertEqual(m.appended,0)
    }
    /// T10 trailing empty desk, other monitor, the desk still exists (on the built-in): kept.
    func testT10TrailingEmptyDeskStillExistsIsKept() {
        let m=map(strip([(1,o),(2,o),(3,e)]),[90],others:[2,3])
        XCTAssertTrue(m.dropped.isEmpty); XCTAssertEqual(m.needed,3)
    }
    /// T11 empty desks at the start.
    func testT11LeadingEmptyDesks() {
        XCTAssertEqual(map(strip([(1,e),(2,e),(3,o)]),[90,91,92],others:[2,3]).slot(forPosition:3),3)
    }
    /// T12 empty middle desk.
    func testT12EmptyMiddleDesk() {
        let m=map(strip([(1,o),(2,e),(3,o)]),[90,91,92],others:[2,3])
        XCTAssertEqual(m.slot(forPosition:1),1); XCTAssertEqual(m.slot(forPosition:3),3)
    }
    /// T13 more desks now than in the strip: the extra ones are left alone.
    func testT13MoreDesksNow() {
        let m=map(strip([(1,o),(2,o)]),[90,91,92,93],others:[2])
        XCTAssertEqual(slots(m),[1,2]); XCTAssertEqual(m.needed,2); XCTAssertEqual(m.appended,0)
    }
    /// T14 an extra desk in the middle (same monitor): Y (0,0,1) beats X (0,1,0); b → desk 3, desk 4 stays empty.
    func testT14ExtraDeskInTheMiddlePrefersPositions() {
        let m=map(strip([(1,o),(10,o),(11,o)]),[90,10,99,11])
        XCTAssertEqual(m.kind,.positional); XCTAssertEqual(slots(m),[1,2,3]); XCTAssertEqual(m.holes,0); XCTAssertEqual(m.moves,1)
        XCTAssertTrue(m.alternative.contains("holes=1"))
    }
    /// T15 a group whose windows were all closed still holds its position.
    func testT15ClosedGroupStillHoldsItsPosition() {
        XCTAssertEqual(map(strip([(1,e),(2,o),(3,o),(4,o)]),[90,91,92,93],others:[2,3,4]).slot(forPosition:4),4)
    }
    /// T16 an identity late in the strip with no room before it: no phantom desk request (V4).
    func testT16LateIdentityDoesNotAskForDesks() {
        let m=map(strip([(1,o),(2,o),(12,o)]),[90,12,95])
        XCTAssertEqual(m.needed,3); XCTAssertEqual(m.appended,0); XCTAssertEqual(slots(m),[1,2,3])
    }
    /// T17 desks cannot be added (full screen app): position 3 waits; the plan still says 3 are needed.
    func testT17CannotAddDesks() {
        let m=map(strip([(1,e),(2,e),(3,o)]),[90],others:[2,3])
        XCTAssertEqual(m.needed,3); XCTAssertEqual(m.slot(forPosition:3),3)
    }
    /// T18 old saved layout (no desk list): ordinals 1 and 3 held windows, 4 desks at save time → L=4.
    func testT18LegacySavedLayoutUsesTheDeskCountAtSaveTime() {
        func sv(_ slot: Int) -> SavedWindow { SavedWindow(selector:WindowSelector(bundleID:"a.\(slot)",title:"T\(slot)"),displayRole:.external,desktopLabel:"g\(slot)",normalizedFrame:Rect(0,0,1,1),desktopIndex:slot) }
        var r=MonitorLayoutRecord(monitor:.sharedExternal,profile:Profile(location:"x",windows:[sv(1),sv(3)]))
        r.coverage=ExternalCaptureCoverage(ordinaryDesktopCount:4,representedDesktopCount:2,readableWindowCount:2)
        let st=DeskStrip(saved:r)
        XCTAssertEqual(st.source,.legacy); XCTAssertEqual(st.count,4); XCTAssertEqual(st.slots.map(\.occupied),[true,false,true,false])
        let m=StripMapper.map(st,current:spaces([90,91,92]),exists:{ _ in true })
        XCTAssertEqual(m.slot(forPosition:1),1); XCTAssertEqual(m.slot(forPosition:3),3); XCTAssertEqual(m.needed,4)
    }
    /// T23 desk 1 held windows and its desk is gone: position 1 is still desk 1.
    func testT23FirstPositionIsPinnedToTheFirstDesk() {
        let m=map(strip([(473,o),(454,o)]),[500,454])
        XCTAssertEqual(m.slot(forPosition:1),1); XCTAssertEqual(m.slot(forPosition:2),2); XCTAssertTrue(m.conflicts.isEmpty)
    }
    /// T24 a reused ID with another uuid is not the same desk.
    func testT24ReusedIDWithAnotherUUIDIsNoAnchor() {
        let st=strip([(1,o),(5,o)],uuids:[5:"A"])
        let m=map(st,[90,7,5],uuids:[5:"B"])
        XCTAssertFalse(m.anchors.contains{ $0.0==1 }); XCTAssertEqual(m.slot(forPosition:2),2)
        XCTAssertFalse(DeskRef(id:5,uuid:"A").same(DeskRef(id:5,uuid:"B")))
        XCTAssertTrue(DeskRef(id:5,uuid:nil).same(DeskRef(id:5,uuid:"B")))
        XCTAssertFalse(DeskRef(id:440,uuid:"H1").strictlySame(DeskRef(id:484,uuid:"H1")),"desk-1 uuid survives, the ID does not")
        XCTAssertTrue(DeskRef(id:440,uuid:"H1").same(DeskRef(id:484,uuid:"H1")))
    }

    // MARK: - Planner and record replays

    let started=Date(timeIntervalSince1970:1_000)
    let freezeAt=Date(timeIntervalSince1970:50_000)
    let extFrame=Rect(-204,-1050,1920,1050), builtInFrame=Rect(0,33,1512,949)
    let ag="com.google.antigravity-ide", chrome="com.google.Chrome"
    let profiles=["9001:514":"Profile 1","9001:437":"Default"]
    func w(_ token: String,_ bundle: String,_ title: String,space: UInt64,_ frame: Rect) -> ObservedWindow {
        ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title),frame:frame,spaceIDs:[space],processStartedAt:started)
    }
    /// `ext` nil = no external display (unplugged); `builtIn` nil = lid closed.
    func snap(ext: String?,extSpaces: [UInt64],builtIn: [UInt64]?,windows: [ObservedWindow],uuids: [UInt64:String]=[:]) -> Snapshot {
        var displays=[Display](), sp=[Space]()
        if let builtIn { displays.append(Display(token:"builtin",name:"内建",role:.builtIn,visible:builtInFrame)); sp+=spaces(builtIn,"builtin",uuids:uuids) }
        if let ext { displays.append(Display(token:ext,name:"Ext",role:.external,visible:extFrame)); sp+=spaces(extSpaces,ext,uuids:uuids) }
        return Snapshot(session:UUID(),topology:"t-\(extSpaces)-\(builtIn ?? [])",displays:displays,spaces:sp,windows:windows)
    }
    func capture(_ s: Snapshot,ext: String,previous: LiveLayoutRecord?=nil) -> LiveLayoutRecord? {
        let v=LiveRecordTrust.assess(snapshot:s,displayToken:ext,previous:previous,screenLocked:false,sinceWake:nil)
        if case .skip=v { return previous }
        var keep: [DeskRef]?
        if case .keepDesks=v { keep=previous?.desks }
        return LiveLayoutRecord.capture(key:"shared-external",monitor:.sharedExternal,displayToken:ext,snapshot:s,browserProfiles:profiles,at:freezeAt.addingTimeInterval(-15),keepingDesks:keep,builtInDesks:previous?.builtInDesks)
    }
    func plan(_ e: EffectiveLayout,_ s: Snapshot,ext: String) throws -> QuickRestorePlan {
        try QuickRestorePlanner.plan(record:e.record,monitor:.sharedExternal,displayToken:ext,snapshot:s,allowCrossSpace:true,browserProfiles:profiles,context:e.context)
    }
    func item(_ p: QuickRestorePlan,_ token: String) -> QuickRestoreItem? { p.items.first{ $0.chosenToken==token } }

    /// The 10/20 21:37 home strip after the user's reorder: [443·,444·,484●IDE×4,446●Chrome P1,445●Chrome Default];
    /// laptop windows on the built-in's own desks 275/277/304. Desk 1 shares its uuid with the old desk 440 (M9).
    let homeUUIDs: [UInt64:String]=[443:"H1",440:"H1",484:"H1-3"]
    var ide: [(String,String)] { [("3711:1","ide-a"),("3711:2","ide-b"),("3711:3","ide-c"),("3711:4","ide-d")] }
    func homeWindows(onExternal: Bool) -> [ObservedWindow] {
        let f=onExternal ? extFrame : builtInFrame
        return ide.map{ w($0.0,ag,"\($0.1) — Antigravity",space:484,f) }+[w("9001:514",chrome,"Docs - Google Chrome - sam",space:446,f),w("9001:437",chrome,"Mail - Google Chrome - alex",space:445,f)]
    }
    var laptopWindows: [ObservedWindow] {
        [w("2634:255","com.example.chat","Chat",space:275,builtInFrame),w("38516:66886","com.example.codex","Codex",space:275,builtInFrame),
         w("68217:61688","com.example.db","DB",space:277,builtInFrame),w("90975:52034","com.example.editor","Editor",space:304,builtInFrame)]
    }
    func homeNormal() -> Snapshot { snap(ext:"home",extSpaces:[443,444,484,446,445],builtIn:[275,277,304],windows:homeWindows(onExternal:true)+laptopWindows,uuids:homeUUIDs) }
    /// Lid closed (10/21 09:00:53): the built-in's 7 desks (own 275/277/304 + parked office 454/458/459/460) are put
    /// before the external's desks; empty desk 1 (443) is destroyed.
    func homeClamshell() -> Snapshot {
        var lw=laptopWindows; for i in lw.indices { lw[i].frame=extFrame }
        return snap(ext:"home",extSpaces:[275,277,304,454,458,459,460,444,484,446,445],builtIn:nil,windows:homeWindows(onExternal:true)+lw,uuids:homeUUIDs)
    }
    /// Office plug, lid open (09:32:26): office desks back [500,454,458,459,460]; the built-in has its own desks and
    /// the home ones.
    func officePlug(moved: [String:UInt64]=[:]) -> Snapshot {
        var ws=homeWindows(onExternal:false)+laptopWindows
        for i in ws.indices { if let d=moved[ws[i].token] { ws[i].spaceIDs=[d]; ws[i].frame=extFrame } }
        return snap(ext:"office",extSpaces:[500,454,458,459,460],builtIn:[275,277,304,444,484,446,445],windows:ws,uuids:homeUUIDs)
    }
    /// The 10/19 23:10 saved home layout: a chat window on desk 1 (440, same uuid as today's 443) and old IDE windows.
    func savedHome1019() -> MonitorLayoutRecord {
        func sv(_ b: String,_ t: String,_ slot: Int,_ id: UInt64) -> SavedWindow { SavedWindow(selector:WindowSelector(bundleID:b,title:t),displayRole:.external,desktopLabel:"g",normalizedFrame:Rect(0,0,1,1),desktopIndex:slot,desktopID:id,desktopUUID:homeUUIDs[id] ?? "U-\(id)") }
        var r=MonitorLayoutRecord(monitor:.sharedExternal,savedAt:Date(timeIntervalSince1970:10_000),profile:Profile(location:"家",windows:[
            sv("com.example.notes","Old notes",1,440),sv(ag,"old-x — Antigravity",3,441),sv(ag,"old-y — Antigravity",3,441)]))
        r.desks=[DeskRef(id:440,uuid:"H1"),DeskRef(id:441,uuid:"U-441"),DeskRef(id:442,uuid:"U-442")]
        return r
    }

    /// T28 (10/21): home → lid closed → unplug → office, lid open. Positions 1–2 empty, 3 IDE, 4 Chrome Profile 1,
    /// 5 Chrome Default; laptop windows untouched; no desk added. T29/T30 ride along.
    func testT28HomeClamshellUnplugOfficePlug() throws {
        let normal=try XCTUnwrap(capture(homeNormal(),ext:"home"))
        XCTAssertEqual(normal.desks.map(\.id),[443,444,484,446,445]); XCTAssertEqual(normal.builtInDesks?.map(\.id),[275,277,304])
        // T21: lid closed. The strip stays the last normal one; the laptop windows count as elsewhere.
        let clam=try XCTUnwrap(capture(homeClamshell(),ext:"home",previous:normal))
        XCTAssertEqual(clam.desks.map(\.id),[443,444,484,446,445],"the built-in's desktops never enter the strip")
        XCTAssertEqual(clam.windows.map(\.desktopIndex),[3,3,3,3,4,5])
        XCTAssertEqual(Set(clam.elsewhere.map(\.runtime.token)),Set(laptopWindows.map(\.token)))
        XCTAssertEqual(clam.builtInDesks?.map(\.id),[275,277,304],"carried while the built-in screen is away")
        let frozen=clam.freezing(ceiling:99_999,at:freezeAt)
        let s=officePlug()
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:savedHome1019(),live:frozen,monitor:.sharedExternal,snapshot:s))
        // T29: windows the record lists as elsewhere are never companions; the built-in's own desks are not migrated.
        XCTAssertFalse(e.context.sources.contains(.companion),"\(e.notes)")
        XCTAssertEqual(e.context.strip?.slots.map(\.occupied),[false,false,true,true,true])
        let p=try plan(e,s,ext:"office")
        for t in ide.map(\.0) { XCTAssertEqual(item(p,t)?.targetSpaceID,458,t); XCTAssertEqual(item(p,t)?.state,.ready) }
        XCTAssertEqual(item(p,"9001:514")?.targetSpaceID,459); XCTAssertEqual(item(p,"9001:437")?.targetSpaceID,460)
        XCTAssertEqual(p.desktopsNeeded,5); XCTAssertEqual(p.missingDesktops,0,"no desk added")
        XCTAssertEqual(Set(p.plan.entries.compactMap(\.targetSpace)),[458,459,460],"desks 1–2 stay empty")
        XCTAssertTrue(laptopWindows.allSatisfy{ lw in !p.plan.entries.contains{ $0.window?.token==lw.token } },"laptop windows untouched")
        // T30: the old saved desk-1 window (desk 440, same uuid as 443) takes no position and moves no group.
        let notes=try XCTUnwrap(p.items.first{ $0.savedTitle=="Old notes" })
        XCTAssertNotEqual(notes.state,.ready); XCTAssertNil(notes.targetSlot)
        XCTAssertEqual(p.groups.compactMap(\.ordinal),[3,4,5])
        XCTAssertTrue(QuickRestorePlanner.autoSubset(p).entries.count==6)
        // After the restore: everything in place (judged by position, not desk ID).
        let after=officePlug(moved:Dictionary(uniqueKeysWithValues:ide.map{ ($0.0,UInt64(458)) }+[("9001:514",459),("9001:437",460)]))
        let p2=try plan(e,after,ext:"office")
        XCTAssertTrue(p2.plan.entries.isEmpty)
        let q=QuickRestorePlanner.quietAlreadyInPlace(p2,record:e.record,snapshot:after,displayToken:"office",browserProfiles:profiles)
        XCTAssertTrue(q.plan.items.filter{ $0.source == .live }.allSatisfy{ $0.state == .alreadyInPlace })
    }
    /// T29 alone: a frozen record that (wrongly or not) lists a built-in desk; the window the record saw elsewhere
    /// stays out, and the built-in screen's own desks are never "migrated".
    func testT29ElsewhereWindowIsNeverACompanion() throws {
        var rec=try XCTUnwrap(capture(homeNormal(),ext:"home"))
        rec.desks.insert(DeskRef(id:275,uuid:"U-275"),at:0)    // as the 10/21 clamshell record had it
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec.freezing(ceiling:99_999,at:freezeAt),monitor:.sharedExternal,snapshot:officePlug()))
        XCTAssertFalse(e.context.sources.contains(.companion))
        rec.builtInDesks=nil; rec.elsewhere=[]
        let e2=try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec.freezing(ceiling:99_999,at:freezeAt),monitor:.sharedExternal,snapshot:officePlug()))
        XCTAssertTrue(e2.context.sources.contains(.companion),"without both guards they would have been taken (the 10/21 bug)")
    }
    /// T19 saved windows of an older record next to a live one: only by their own desk (strict), never by ordinal.
    func testT19OlderSavedWindowsTakeNoPositionByOrdinal() throws {
        let rec=try XCTUnwrap(capture(homeNormal(),ext:"home")).freezing(ceiling:99_999,at:freezeAt)
        var saved=savedHome1019()
        saved.profile.windows.append(SavedWindow(selector:WindowSelector(bundleID:"com.example.mail",title:"Inbox"),displayRole:.external,desktopLabel:"g",normalizedFrame:Rect(0,0,1,1),desktopIndex:5,desktopID:445,desktopUUID:"U-445"))
        var s=officePlug(); s.windows.append(w("777:1","com.example.mail","Inbox",space:445,builtInFrame))
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:saved,live:rec,monitor:.sharedExternal,snapshot:s))
        let p=try plan(e,s,ext:"office")
        XCTAssertEqual(item(p,"777:1")?.targetSpaceID,460,"own desk 445 is position 5 of the live strip")
        let old=try XCTUnwrap(p.items.first{ $0.savedTitle=="old-x — Antigravity" })
        XCTAssertNil(old.targetSlot)
    }
    /// T20 a 0.6.11 saved layout with empty desks behaves like the live strip.
    func testT20SavedLayoutWithDeskListKeepsEmptyPositions() throws {
        let (r,_)=try ExternalLayoutCapture.capture(monitor:.sharedExternal,displayToken:"home",snapshot:homeNormal())
        XCTAssertEqual(r.desks?.map(\.id),[443,444,484,446,445]); XCTAssertEqual(r.occupiedDesks,[484,446,445])
        let st=DeskStrip(saved:r)
        XCTAssertEqual(st.source,.saved); XCTAssertEqual(st.slots.map(\.occupied),[false,false,true,true,true])
        let s=officePlug()
        let p=try QuickRestorePlanner.plan(record:r,monitor:.sharedExternal,displayToken:"office",snapshot:s,allowCrossSpace:true,browserProfiles:profiles)
        XCTAssertEqual(p.desktopsNeeded,5); XCTAssertEqual(p.missingDesktops,0)
        XCTAssertEqual(p.items.first{ $0.bundleID==chrome && $0.savedTitle.hasPrefix("Mail") }?.targetSpaceID,460)
        // Schema: the new fields round-trip, and a layout without them still loads.
        let data=try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(MonitorLayoutRecord.self,from:data).desks,r.desks)
        var old=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        old["desks"]=nil; old["occupiedDesks"]=nil
        let legacy=try JSONDecoder().decode(MonitorLayoutRecord.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertNil(legacy.desks); XCTAssertEqual(DeskStrip(saved:legacy).source,.legacy); XCTAssertEqual(DeskStrip(saved:legacy).count,5)
    }
    /// T22 sleep/wake with the monitor still there: everything is already in place.
    func testT22WakeOnTheSameMonitorMovesNothing() throws {
        let s=homeNormal()
        let rec=try XCTUnwrap(capture(s,ext:"home")).freezing(ceiling:99_999,at:freezeAt)
        let p=try plan(try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec,monitor:.sharedExternal,snapshot:s)),s,ext:"home")
        XCTAssertTrue(p.plan.entries.isEmpty); XCTAssertTrue(p.items.allSatisfy{ $0.state == .alreadyInPlace })
        XCTAssertEqual(p.mapping?.kind,.anchored)
    }
    /// T5 replay: same monitor, desks reversed → windows move back into the recorded order, with a notice.
    func testT5ReplayReversedDesksPutsWindowsBackInOrder() throws {
        let rec=try XCTUnwrap(capture(homeNormal(),ext:"home")).freezing(ceiling:99_999,at:freezeAt)
        // Replug: desk 1 new (490), the others back reversed: [490,445,446,484,444]; windows stayed with their desks.
        let s=snap(ext:"home",extSpaces:[490,445,446,484,444],builtIn:[275,277,304],windows:homeWindows(onExternal:true)+laptopWindows,uuids:[484:"H1-3"])
        let p=try plan(try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec,monitor:.sharedExternal,snapshot:s)),s,ext:"home")
        XCTAssertEqual(item(p,"3711:1")?.targetSpaceID,446,"position 3 = the 3rd desk now, not its own desk 484 (4th)")
        XCTAssertEqual(item(p,"9001:514")?.targetSpaceID,484); XCTAssertEqual(item(p,"9001:437")?.targetSpaceID,444)
        XCTAssertEqual(p.mapping?.kind,.positional)
        XCTAssertFalse(p.stripNotices.isEmpty)
        XCTAssertEqual(p.missingDesktops,0)
    }
    /// T25 the record follows a reorder made on the monitor (M8), so the next restore uses the new order.
    func testT25RecordFollowsAReorder() throws {
        var s=homeNormal()
        s.spaces=spaces([275,277,304],"builtin")+spaces([443,484,444,446,445],"home",uuids:homeUUIDs)
        let rec=try XCTUnwrap(capture(s,ext:"home"))
        XCTAssertEqual(rec.desks.map(\.id),[443,484,444,446,445]); XCTAssertEqual(DeskStrip(live:rec).slots.map(\.occupied),[false,true,false,true,true])
    }
    /// T26 two windows of one position from two sources: the position comes from the strip, never a min ordinal.
    func testT26PositionComesFromTheStrip() throws {
        let rec=try XCTUnwrap(capture(homeNormal(),ext:"home")).freezing(ceiling:99_999,at:freezeAt)
        var saved=savedHome1019()
        saved.profile.windows.append(SavedWindow(selector:WindowSelector(bundleID:"com.example.mail",title:"Inbox"),displayRole:.external,desktopLabel:"g",normalizedFrame:Rect(0,0,1,1),desktopIndex:1,desktopID:484,desktopUUID:"H1-3"))
        var s=officePlug(); s.windows.append(w("777:1","com.example.mail","Inbox",space:484,builtInFrame))
        let p=try plan(try XCTUnwrap(EffectiveLayout.compose(saved:saved,live:rec,monitor:.sharedExternal,snapshot:s)),s,ext:"office")
        XCTAssertEqual(item(p,"777:1")?.targetSpaceID,458,"desk 484 is position 3 although that layout said ordinal 1")
        XCTAssertEqual(item(p,"3711:1")?.targetSpaceID,458)
    }
    /// T27 while waiting for desks (or during any untrusted state) the strip does not change.
    func testT27StripUnchangedWhileWaiting() throws {
        let normal=try XCTUnwrap(capture(homeNormal(),ext:"home"))
        var locked=homeNormal(); locked.windows=[]
        XCTAssertEqual(capture(locked,ext:"home",previous:normal),normal)
    }

    // MARK: - Record trust (T21, T31, T32)

    func testT21ClamshellVerdict() throws {
        let normal=try XCTUnwrap(capture(homeNormal(),ext:"home"))
        guard case .keepDesks=LiveRecordTrust.assess(snapshot:homeClamshell(),displayToken:"home",previous:normal,screenLocked:false,sinceWake:nil) else { return XCTFail() }
        XCTAssertEqual(LiveRecordTrust.assess(snapshot:homeNormal(),displayToken:"home",previous:normal,screenLocked:false,sinceWake:nil),.normal)
        // Always working with the lid closed (no built-in desks known): normal.
        var noBuiltIn=normal; noBuiltIn.builtInDesks=nil
        XCTAssertEqual(LiveRecordTrust.assess(snapshot:homeClamshell(),displayToken:"home",previous:noBuiltIn,screenLocked:false,sinceWake:nil),.normal)
    }
    /// T31 right after wake (the ghost monitor): no record; T32 locked or zero windows: no record.
    func testT31T32UntrustedScansChangeNothing() throws {
        let normal=try XCTUnwrap(capture(homeNormal(),ext:"home"))
        guard case .skip=LiveRecordTrust.assess(snapshot:homeNormal(),displayToken:"home",previous:normal,screenLocked:false,sinceWake:3) else { return XCTFail("wake grace") }
        guard case .skip=LiveRecordTrust.assess(snapshot:homeNormal(),displayToken:"home",previous:normal,screenLocked:true,sinceWake:nil) else { return XCTFail("locked") }
        var empty=homeClamshell(); empty.windows=[]
        guard case .skip=LiveRecordTrust.assess(snapshot:empty,displayToken:"home",previous:normal,screenLocked:false,sinceWake:nil) else { return XCTFail("zero windows") }
        XCTAssertEqual(LiveRecordTrust.assess(snapshot:homeNormal(),displayToken:"home",previous:normal,screenLocked:false,sinceWake:30),.normal)
    }

    // MARK: - Logs and messages

    func testStripLogLines() throws {
        let rec=try XCTUnwrap(capture(homeNormal(),ext:"home")).freezing(ceiling:99_999,at:freezeAt)
        let s=officePlug()
        let p=try plan(try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec,monitor:.sharedExternal,snapshot:s)),s,ext:"office")
        let lines=RestoreLog.deskMapLines(trigger:"auto",plan:p)
        XCTAssertTrue(lines[0].hasPrefix("strip: auto source=live"),lines[0]); XCTAssertTrue(lines[0].contains("[1:443· 2:444· 3:484● 4:446● 5:445●]"))
        XCTAssertTrue(lines[1].contains("needed=5")); XCTAssertTrue(lines[1].contains("plan=anchored"))
        XCTAssertTrue(lines.contains{ $0.hasPrefix("strip: auto pos3 desk=484 windows=4") })
    }
    func testScanIssueSummaryNamesOnlyLayoutApps() {
        let issues=["com.google.Chrome：AXMessagingTimeout -25204","com.example.unrelated：CG 窗口归属未确认","123:456：窗口已关闭、所属进程不可用或窗口引用已改变","3 个已枚举窗口无法回读，未保存其布局"]
        let r=ScanIssueSummary.summarize(issues,layoutApps:["com.google.Chrome","com.google.antigravity-ide"])
        XCTAssertEqual(r.affectedApps,["com.google.Chrome"]); XCTAssertEqual(r.windows,4); XCTAssertEqual(r.unrelated,1)
        XCTAssertTrue(ScanIssueSummary.text(r,appName:{ _ in "Chrome" })?.contains("Chrome 的窗口这次没读全") == true)
        XCTAssertNil(ScanIssueSummary.text(ScanIssueSummary.summarize(["com.example.unrelated：x"],layoutApps:["a"]),appName:{ $0 }))
    }

    // MARK: - 0.6.12 optimizations: pre-scan lock/wake gate, clamshell new-desk & reconnect, live-vs-saved stale summary

    func testPreScanSkipReasonStopsLockedAndWakeGraceBeforeScanning() {
        XCTAssertEqual(LiveRecordTrust.preScanSkipReason(screenLocked:true,sinceWake:nil),"screen locked or displays asleep")
        XCTAssertEqual(LiveRecordTrust.preScanSkipReason(screenLocked:false,sinceWake:2.4),"2s after wake")
        XCTAssertNil(LiveRecordTrust.preScanSkipReason(screenLocked:false,sinceWake:8.0))
        XCTAssertNil(LiveRecordTrust.preScanSkipReason(screenLocked:false,sinceWake:nil))
    }

    func testClamshellNewDesktopCreatedWhileLidClosedIsAddedToStripAndRecorded() throws {
        let normal=try XCTUnwrap(capture(homeNormal(),ext:"home"))
        let clam1=try XCTUnwrap(capture(homeClamshell(),ext:"home",previous:normal))
        XCTAssertEqual(clam1.desks.map(\.id),[443,444,484,446,445])
        // User creates a new desktop 510 in Mission Control while the lid is closed and opens a Notes window on it.
        var clamWithNew=homeClamshell()
        clamWithNew.spaces.append(Space(id:510,displayToken:"home",active:true,uuid:"U-510"))
        let newWin=w("9500:1","com.example.notes","Clamshell Note",space:510,extFrame)
        clamWithNew.windows.append(newWin)
        let clam2=try XCTUnwrap(capture(clamWithNew,ext:"home",previous:clam1))
        XCTAssertEqual(clam2.desks.map(\.id),[443,444,484,446,445,510],"newly created external desktop in clamshell mode is appended to the strip")
        let recordedNote=try XCTUnwrap(clam2.windows.first{ $0.runtime?.token=="9500:1" })
        XCTAssertEqual(recordedNote.desktopIndex,6)
        XCTAssertEqual(recordedNote.desktopID,510)
        XCTAssertFalse(clam2.elsewhere.contains{ $0.runtime.token=="9500:1" },"window on the new clamshell desktop is recorded, not elsewhere")
        XCTAssertEqual(clam2.builtInDesks?.map(\.id),[275,277,304],"builtInDesks stays preserved throughout the clamshell session")
        // Normal clamshell-only session (no keepingDesks) never carries dormant builtInDesks that could re-arm later.
        let pureClam=try XCTUnwrap(LiveLayoutRecord.capture(key:"shared-external",monitor:.sharedExternal,displayToken:"home",snapshot:homeClamshell(),browserProfiles:profiles,at:freezeAt,keepingDesks:nil,builtInDesks:normal.builtInDesks))
        XCTAssertNil(pureClam.builtInDesks)
    }

    func testClosedLiveWindowIsNotReportedAsStaleSavedWindow() throws {
        let rec=try XCTUnwrap(capture(homeNormal(),ext:"home")).freezing(ceiling:99_999,at:freezeAt)
        var s=officePlug()
        // Close the live Chrome Default window (9001:437) while keeping an unrelated saved window closed too.
        s.windows.removeAll{ $0.token=="9001:437" }
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:savedHome1019(),live:rec,monitor:.sharedExternal,snapshot:s))
        let p=try plan(e,s,ext:"office")
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:e.record,snapshot:s,displayToken:"office",browserProfiles:profiles)
        let liveClosed=try XCTUnwrap(q.plan.items.first{ $0.source == .live && $0.bundleID==chrome && $0.chosenToken == nil })
        XCTAssertEqual(liveClosed.state,.missing)
        XCTAssertFalse(liveClosed.stale,"closed live-record window must not be flagged as a stale saved window")
        XCTAssertEqual(liveClosed.reason,lk("拔屏前记下的这个窗口已关闭"))
        // Only the closed window from the manual saved layout (Antigravity) appears in staleSummary.
        let summary=q.plan.staleSummary{ $0 }
        XCTAssertFalse(summary.contains{ $0.contains(chrome) })
    }
}
