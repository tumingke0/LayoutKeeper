// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

/// 0.6.9: desk identity, the live record, the merge with the saved layout, and group-wise desk mapping.
/// The replay tests use the desk IDs, window numbers and frames from the 10/17 and 10/19 restore logs; titles and
/// profile names are neutral stand-ins.
final class DeskIdentityTests: XCTestCase {
    let started=Date(timeIntervalSince1970:1_000)
    let freezeAt=Date(timeIntervalSince1970:50_000)
    let homeFrame=Rect(-204,-1050,1920,1050), officeFrame=Rect(-234,-1050,1920,1050), builtInFrame=Rect(0,33,1512,949)
    let ag="com.google.antigravity-ide", chrome="com.google.Chrome"
    let profiles=["9001:514":"Profile 1","9001:437":"Default","9001:46521":"Profile 2"]

    func w(_ token: String,_ bundle: String,_ title: String,space: UInt64?,_ frame: Rect,minimized: Bool=false,started: Date?=nil) -> ObservedWindow {
        ObservedWindow(token:token,selector:WindowSelector(bundleID:bundle,title:title),frame:frame,spaceIDs:space.map{ [$0] } ?? [],minimized:minimized,processStartedAt:started ?? self.started)
    }
    func snapshot(ext: String,_ extVisible: Rect,extSpaces: [UInt64],builtIn: [UInt64],windows: [ObservedWindow]) -> Snapshot {
        var spaces=builtIn.enumerated().map{ Space(id:$0.element,displayToken:"builtin",active:$0.offset==0,uuid:"U-\($0.element)") }
        spaces+=extSpaces.enumerated().map{ Space(id:$0.element,displayToken:ext,active:$0.offset==0,uuid:"U-\($0.element)") }
        var displays=[Display(token:"builtin",name:"内建",role:.builtIn,visible:builtInFrame)]
        if !extSpaces.isEmpty { displays.append(Display(token:ext,name:"Ext",role:.external,visible:extVisible)) }
        return Snapshot(session:UUID(),topology:"t-\(extSpaces)",displays:displays,spaces:spaces,windows:windows)
    }
    func saved(_ bundle: String,_ title: String,slot: Int,profile: String?=nil) -> SavedWindow {
        var s=SavedWindow(selector:WindowSelector(bundleID:bundle,title:title),displayRole:.external,desktopLabel:"组-\(slot)",normalizedFrame:Rect(0,0,1,1),desktopIndex:slot)
        s.browserProfile=profile; return s
    }
    func sharedRecord(_ windows: [SavedWindow]) -> MonitorLayoutRecord { MonitorLayoutRecord(monitor:.sharedExternal,profile:Profile(location:"共用",windows:windows)) }
    func live(_ s: Snapshot,ext: String,ceiling: UInt32?) -> LiveLayoutRecord {
        LiveLayoutRecord.capture(key:"shared-external",monitor:.sharedExternal,displayToken:ext,snapshot:s,browserProfiles:profiles,at:freezeAt.addingTimeInterval(-15))!
            .freezing(ceiling:ceiling,at:freezeAt)
    }
    func plan(_ e: EffectiveLayout,_ s: Snapshot,ext: String,choices: [Int:QuickChoice]=[:]) throws -> QuickRestorePlan {
        try QuickRestorePlanner.plan(record:e.record,monitor:.sharedExternal,displayToken:ext,snapshot:s,choices:choices,allowCrossSpace:true,browserProfiles:profiles,context:e.context)
    }
    func index(_ p: QuickRestorePlan,_ token: String) -> Int? { p.items.firstIndex{ $0.chosenToken==token } }

    // MARK: - 10/17 home replug: identities 255/254/141 present → nothing moves

    /// 10/17 15:23 home monitor d:83238b: desks [259,6,255,254,141]; 4 Antigravity windows on 255 (slot 3), Chrome
    /// Profile 1 on 254 (slot 4), Chrome Default on 141 (slot 5). Unplug 15:24:24, desk 6 removed, replug 15:26:31:
    /// desks [315,255,254,141]. 0.6.8 mapped by ordinal and moved everything one desk to the left.
    func homeBefore() -> Snapshot {
        snapshot(ext:"home",homeFrame,extSpaces:[259,6,255,254,141],builtIn:[3],windows:[
            w("3711:26053",ag,"queue-tool — Antigravity",space:255,homeFrame),w("3711:29534",ag,"project-a — Antigravity",space:255,homeFrame),
            w("3711:387",ag,"project-b — Antigravity",space:255,homeFrame),w("3711:388",ag,"project-c — Antigravity",space:255,homeFrame),
            w("9001:514",chrome,"Docs - Google Chrome - sam",space:254,homeFrame),w("9001:437",chrome,"Mail - Google Chrome - alex",space:141,homeFrame)])
    }
    func homeReplugged(_ before: Snapshot) -> Snapshot {
        snapshot(ext:"home",homeFrame,extSpaces:[315,255,254,141],builtIn:[3],windows:before.windows)
    }
    func test1017ReplugWithDeskIdentityMovesNothing() throws {
        let rec=live(homeBefore(),ext:"home",ceiling:29600)
        XCTAssertEqual(rec.windows.map(\.desktopID),[255,255,255,255,254,141])
        XCTAssertEqual(rec.desks.map(\.id),[259,6,255,254,141])
        // An older ordinal-only saved layout: one window matches a live one, one was closed since.
        let savedLayout=sharedRecord([saved(ag,"project-a — Antigravity",slot:3),saved(ag,"closed-x — Antigravity",slot:3),
                                      saved(chrome,"Old - Google Chrome - alex",slot:5,profile:"Default"),saved(chrome,"Old2 - Google Chrome - sam",slot:4,profile:"Profile 1")])
        let s=homeReplugged(homeBefore())
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:savedLayout,live:rec,monitor:.sharedExternal,snapshot:s))
        XCTAssertEqual(e.context.sources,[.live,.live,.live,.live,.live,.live,.saved],"3 saved windows correspond to live ones; the closed one stays")
        XCTAssertEqual(e.record.profile.windows[6].desktopID,255,"ordinal-only saved window joins the live desk with its ordinal")
        let p=try plan(e,s,ext:"home")
        for i in 0..<6 {
            XCTAssertEqual(p.items[i].state,.alreadyInPlace,"#\(i)"); XCTAssertEqual(p.items[i].deskMapping,.identity); XCTAssertEqual(p.items[i].matchKind,.runtime)
        }
        XCTAssertEqual(p.items[0...3].map(\.targetSlot),[2,2,2,2]); XCTAssertEqual(p.items[4].targetSlot,3); XCTAssertEqual(p.items[5].targetSlot,4)
        XCTAssertTrue(p.plan.entries.isEmpty,"nothing moves")
        XCTAssertEqual(p.missingDesktops,0)
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:e.record,snapshot:s,displayToken:"home",browserProfiles:profiles)
        XCTAssertEqual(q.plan.items[6].state,.missing); XCTAssertTrue(q.plan.items[6].stale)
        XCTAssertTrue(QuickRestorePlanner.autoSubset(q.plan).entries.isEmpty)
    }
    /// Same replug with titles changed in between: the runtime identity still recognises every window.
    func test1017RenamedWindowsAreStillTheSameWindows() throws {
        let rec=live(homeBefore(),ext:"home",ceiling:29600)
        var s=homeReplugged(homeBefore())
        for i in s.windows.indices { s.windows[i].selector.title+=" (edited)" }
        let p=try plan(try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec,monitor:.sharedExternal,snapshot:s)),s,ext:"home")
        XCTAssertTrue(p.items.allSatisfy{ $0.state == .alreadyInPlace && $0.matchKind == .runtime })
    }
    /// A relaunched app reuses neither the window number nor the launch date: no runtime match, back to titles.
    func testRuntimeIdentityNeedsTheSameProcessRun() {
        let id=RuntimeWindowIdentity(token:"3711:26053",processStartedAt:started)
        XCTAssertTrue(id.matches(w("3711:26053",ag,"x",space:1,homeFrame)))
        XCTAssertFalse(id.matches(w("3711:26053",ag,"x",space:1,homeFrame,started:started.addingTimeInterval(60))))
        XCTAssertFalse(RuntimeWindowIdentity(token:"3711:26053",processStartedAt:nil).matches(w("3711:26053",ag,"x",space:1,homeFrame)))
        XCTAssertEqual(id.windowID,26053)
    }

    // MARK: - 10/19 office plug: compress groups, never merge

    /// 10/18 21:55 last home state: desks [393,255,254,319,141]; queue-tool on 254 (slot 3), Chrome Profile 1 on 319
    /// (slot 4), Chrome Default on 141 (slot 5). Unplug 12:52:18 → built-in [275,277,304,255,254,319,141].
    /// Office plug 12:54:02 → office d:18c5e5 has one desk [413] holding only a minimized Chrome (Profile 2).
    func homeLastState() -> Snapshot {
        snapshot(ext:"home",homeFrame,extSpaces:[393,255,254,319,141],builtIn:[275,277,304],windows:[
            w("3711:45137",ag,"queue-tool — Antigravity",space:254,homeFrame),
            w("9001:514",chrome,"Docs - Google Chrome - sam",space:319,homeFrame),w("9001:437",chrome,"Mail - Google Chrome - alex",space:141,homeFrame)])
    }
    func officePlugged(desks: [UInt64],moved: [String:UInt64]=[:]) -> Snapshot {
        let onBuiltIn=Rect(0,33,1512,949)
        func at(_ t: String,_ home: UInt64) -> (UInt64,Rect) { moved[t].map{ ($0,officeFrame) } ?? (home,onBuiltIn) }
        let (q,qf)=at("3711:45137",254),(p1,p1f)=at("9001:514",319),(d,df)=at("9001:437",141)
        return snapshot(ext:"office",officeFrame,extSpaces:desks,builtIn:[275,277,304,255,254,319,141],windows:[
            w("3711:45137",ag,"queue-tool — Antigravity",space:q,qf),
            w("9001:514",chrome,"Docs - Google Chrome - sam",space:p1,p1f),w("9001:437",chrome,"Mail - Google Chrome - alex",space:d,df),
            w("9001:46521",chrome,"Other - Google Chrome - sam",space:413,officeFrame,minimized:true),
            w("9001:2096",chrome,"Hidden - Google Chrome - sam",space:nil,officeFrame,minimized:true)])
    }
    /// The 10/17 21:48 saved layout (0.6.8, ordinals only): two Antigravity windows since closed, both Chrome profiles.
    func savedLayout1017() -> MonitorLayoutRecord {
        sharedRecord([saved(ag,"project-a — Antigravity",slot:3),saved(ag,"project-b — Antigravity",slot:3),
                      saved(chrome,"Old - Google Chrome - alex",slot:5,profile:"Default"),saved(chrome,"Old2 - Google Chrome - sam",slot:4,profile:"Profile 1")])
    }
    func test1019OfficePlugCompressesGroupsOntoFreeDesksAndAsksForTheMissingOnes() throws {
        let rec=live(homeLastState(),ext:"home",ceiling:46000)
        let s1=officePlugged(desks:[413])
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:savedLayout1017(),live:rec,monitor:.sharedExternal,snapshot:s1))
        XCTAssertEqual(e.context.sources,[.live,.live,.live,.saved,.saved],"Chrome saved windows correspond by profile; the closed Antigravity ones stay")
        XCTAssertEqual(e.record.profile.windows[3...].map(\.desktopID),[254,254],"they join the queue-tool desk (same ordinal 3)")
        // Step 1, one desk: the queue-tool group takes it; each Chrome group waits for its own desk.
        let p1=try plan(e,s1,ext:"office")
        let q=try XCTUnwrap(index(p1,"3711:45137"))
        XCTAssertEqual(p1.items[q].state,.ready); XCTAssertEqual(p1.items[q].targetSpaceID,413); XCTAssertEqual(p1.items[q].deskMapping,.grouped)
        XCTAssertTrue(QuickRestorePlanner.autoEligible(p1.items[q]))
        XCTAssertEqual(p1.items[1].state,.blocked); XCTAssertEqual(p1.items[2].state,.blocked)
        XCTAssertTrue(p1.items[1].reason.contains("还缺 2 个桌面"))
        XCTAssertEqual(p1.desktopsNeeded,3); XCTAssertEqual(p1.missingDesktops,2,"2 desks, not 4 (ordinal 5 − 1)")
        XCTAssertEqual(p1.plan.entries.map(\.targetSpace),[413],"nothing piles onto the last desk")
        XCTAssertEqual(p1.items[3].state,.missing); XCTAssertTrue(p1.items[3].stale); XCTAssertTrue(p1.items[4].stale)
        XCTAssertEqual(p1.staleSummary{ _ in "Antigravity" },["Antigravity：保存的 2 个窗口已关闭，现在开着的是另外 1 个窗口"])
        // Step 2, after auto-add: [413,416,417]; queue-tool already on 413.
        let s2=officePlugged(desks:[413,416,417],moved:["3711:45137":413])
        let p2=try plan(e,s2,ext:"office")
        XCTAssertEqual(p2.items[0].state,.alreadyInPlace)
        XCTAssertEqual(p2.items[1].targetSpaceID,416); XCTAssertEqual(p2.items[2].targetSpaceID,417)
        XCTAssertEqual(p2.items[1].state,.ready); XCTAssertEqual(p2.items[2].state,.ready)
        XCTAssertTrue(p2.items[1...2].allSatisfy{ QuickRestorePlanner.autoEligible($0) && $0.matchKind == .runtime })
        XCTAssertEqual(p2.missingDesktops,0)
        let slots=p2.groups.compactMap(\.slot)
        XCTAssertEqual(slots.count,Set(slots).count,"no two groups share a desk"); XCTAssertEqual(slots,[1,2,3])
        // Step 3 (re-check): everything in place, nothing moves.
        let s3=officePlugged(desks:[413,416,417],moved:["3711:45137":413,"9001:514":416,"9001:437":417])
        XCTAssertTrue(try plan(e,s3,ext:"office").plan.entries.isEmpty)
    }
    /// Without any live record (first plug after updating), the old saved layout alone still never merges groups.
    func test1019WithoutLiveRecordStillNeverMergesGroups() throws {
        let s1=officePlugged(desks:[413])
        let p=try QuickRestorePlanner.plan(record:savedLayout1017(),monitor:.sharedExternal,displayToken:"office",snapshot:s1,allowCrossSpace:true,browserProfiles:profiles)
        let slots=p.groups.compactMap(\.slot)
        XCTAssertEqual(slots.count,Set(slots).count)
        XCTAssertEqual(p.plan.entries.count,1,"one group placed on the single desk")
        XCTAssertGreaterThan(p.missingDesktops,0)
    }

    // MARK: - Merge semantics

    func testMergeLiveWinsAndSavedExtrasKeepTheirDesk() throws {
        let s=homeBefore()
        let rec=LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:s,browserProfiles:profiles)!
        var withID=saved("com.example.notes","Notes",slot:5); withID.desktopID=141
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([
            saved(ag,"project-b — Antigravity",slot:1),               // same exact title as a live window → dropped (live wins, even on another desk)
            saved(chrome,"Mail - Google Chrome - alex",slot:2),       // same browser title → dropped
            saved(chrome,"Unrelated - Google Chrome - sam",slot:4,profile:"Profile 1"),  // same profile folder, 1 saved ≤ 1 live → dropped
            withID,                                                   // own desk identity, no live counterpart → kept, uuid filled in
            saved("com.example.editor","Draft",slot:2)]),             // ordinal 2 has no live windows (desk 6) → stays its own group
            live:rec,monitor:.sharedExternal))
        XCTAssertEqual(e.context.sources.filter{ $0 == .live }.count,6)
        let extras=Array(e.record.profile.windows[6...])
        XCTAssertEqual(extras.map(\.selector.title),["Notes","Draft"])
        XCTAssertEqual(extras[0].desktopUUID,"U-141"); XCTAssertNil(extras[1].desktopID)
        XCTAssertTrue(extras.allSatisfy{ $0.runtime == nil })
    }
    func testMergeProfileCorrespondenceIsOneToOneAndCountAware() throws {
        let rec=LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:homeBefore(),browserProfiles:profiles)!
        // Two saved Profile 1 windows but only one live → profile alone proves nothing; both kept.
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([saved(chrome,"A - Google Chrome - sam",slot:4,profile:"Profile 1"),saved(chrome,"B - Google Chrome - sam",slot:4,profile:"Profile 1")]),live:rec,monitor:.sharedExternal))
        XCTAssertEqual(e.context.sources.filter{ $0 == .saved }.count,2)
        // Two saved with the same title, one live with it → only one is absorbed.
        let e2=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([saved(ag,"project-a — Antigravity",slot:3),saved(ag,"project-a — Antigravity",slot:3)]),live:rec,monitor:.sharedExternal))
        XCTAssertEqual(e2.context.sources.filter{ $0 == .saved }.count,1)
    }
    func testSavedWindowThatWasOnTheBuiltInScreenAtUnplugStaysThere() throws {
        var s=homeBefore()
        s.windows.append(w("5000:12",ag,"laptop-only — Antigravity",space:3,builtInFrame))
        let rec=LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:s,browserProfiles:profiles)!
        XCTAssertEqual(rec.elsewhere.map(\.runtime.token),["5000:12"])
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([saved(ag,"laptop-only — Antigravity",slot:2)]),live:rec,monitor:.sharedExternal))
        XCTAssertFalse(e.record.profile.windows.contains{ $0.selector.title=="laptop-only — Antigravity" })
        XCTAssertTrue(e.notes.contains{ $0.contains("another display at the unplug") })
    }
    /// Saved-only windows next to a live record get certain matches only and never a live-record window.
    func testSavedExtrasNeverGuessOrStealLiveWindows() throws {
        let rec=live(homeLastState(),ext:"home",ceiling:46000)
        let s=officePlugged(desks:[413,416,417])
        // A renamed editor window open on the built-in screen, the only window of its app (0.6.8 took it as onlyWindow).
        var s2=s; s2.windows.append(w("6000:5","com.example.editor","Renamed",space:275,builtInFrame))
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([saved("com.example.editor","Original",slot:3)]),live:rec,monitor:.sharedExternal,snapshot:s2))
        let p=try plan(e,s2,ext:"office")
        let extra=p.items.last!
        XCTAssertNotEqual(extra.state,.ready); XCTAssertNil(extra.chosenToken)
        let q=QuickRestorePlanner.quietAlreadyInPlace(p,record:e.record,snapshot:s2,displayToken:"office",browserProfiles:profiles)
        XCTAssertTrue(q.plan.items.last!.stale)
        // Without a live record the old rule still applies (only window of the app).
        let old=try QuickRestorePlanner.plan(record:sharedRecord([saved("com.example.editor","Original",slot:3)]),monitor:.sharedExternal,displayToken:"office",snapshot:s2,allowCrossSpace:true)
        XCTAssertEqual(old.items[0].matchKind,.onlyWindow)
    }

    // MARK: - Migrated-desk evidence and companions

    func testRenamedSavedWindowOnItsMigratedDeskIsCertain() throws {
        let rec=live(homeLastState(),ext:"home",ceiling:46000)
        var s=officePlugged(desks:[413,416,417])
        // Saved (0.6.9 layout, with desk identity) on desk 319; on the built-in screen now, renamed. Not in the live
        // record (say the last scan missed it).
        s.windows.append(w("7000:900","com.example.notes","Renamed notes",space:319,builtInFrame))
        var sv=saved("com.example.notes","Notes",slot:4); sv.desktopID=319; sv.desktopUUID="U-319"
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([sv]),live:rec,monitor:.sharedExternal,snapshot:s))
        XCTAssertEqual(e.context.sources.last,.savedDeskEvidence)
        let p=try plan(e,s,ext:"office")
        let item=p.items.last!
        XCTAssertEqual(item.matchKind,.deskEvidence); XCTAssertEqual(item.chosenToken,"7000:900")
        XCTAssertEqual(item.targetSpaceID,416,"with the Chrome Profile 1 group (same desk 319)")
        XCTAssertTrue(QuickRestorePlanner.autoEligible(item))
        // Another app's window on that desk is not evidence for this one.
        var other=s; other.windows[other.windows.count-1].selector.bundleID="com.example.other"
        let e2=try XCTUnwrap(EffectiveLayout.compose(saved:sharedRecord([sv]),live:rec,monitor:.sharedExternal,snapshot:other))
        XCTAssertEqual(e2.context.sources.dropLast().last,.saved)
    }
    func testCompanionsComeBackWithTheirDeskButNotWindowsCreatedAfterTheUnplug() throws {
        let rec=live(homeLastState(),ext:"home",ceiling:46000)
        var s=officePlugged(desks:[413,416,417])
        s.windows.append(w("3711:45100",ag,"side — Antigravity",space:254,builtInFrame))           // existed at the unplug
        s.windows.append(w("3711:47000",ag,"opened later — Antigravity",space:254,builtInFrame))   // ID above the ceiling
        s.windows.append(w("8000:10","com.example.new","x",space:254,builtInFrame,started:freezeAt.addingTimeInterval(10)))  // app launched later
        let e=try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec,monitor:.sharedExternal,snapshot:s))
        XCTAssertEqual(e.context.sources,[.live,.live,.live,.companion])
        let p=try plan(e,s,ext:"office")
        XCTAssertEqual(p.items[3].chosenToken,"3711:45100"); XCTAssertEqual(p.items[3].targetSpaceID,413,"same group as queue-tool")
        XCTAssertTrue(QuickRestorePlanner.autoEligible(p.items[3]))
        XCTAssertNil(index(p,"3711:47000")); XCTAssertNil(index(p,"8000:10"))
    }
    func testNoCompanionsWithoutAFrozenCeiling() throws {
        let rec=LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:homeLastState())!.freezing(ceiling:nil,at:freezeAt)
        var s=officePlugged(desks:[413])
        s.windows.append(w("3711:45100",ag,"side — Antigravity",space:254,builtInFrame))
        XCTAssertFalse(try XCTUnwrap(EffectiveLayout.compose(saved:nil,live:rec,monitor:.sharedExternal,snapshot:s)).context.sources.contains(.companion))
    }

    // MARK: - Desk mapper

    func testDeskMapperIdentityOrdinalAndGrouped() {
        let target=[Space(id:1,displayToken:"x"),Space(id:2,displayToken:"x",uuid:"B"),Space(id:3,displayToken:"x"),Space(id:4,displayToken:"x")]
        let groups=[DeskMapper.Group(key:"a",ordinal:1,desk:DeskRef(id:90,uuid:"Z"),windows:1),   // gone → grouped
                    DeskMapper.Group(key:"b",ordinal:2,desk:DeskRef(id:77,uuid:"B"),windows:2),   // uuid match beats id
                    DeskMapper.Group(key:"c",ordinal:5,desk:nil,windows:1),                       // old record, ordinal 5 missing → grouped
                    DeskMapper.Group(key:"d",ordinal:6,desk:DeskRef(id:91,uuid:nil),windows:1)]
        let m=DeskMapper.map(groups,target:target)
        XCTAssertEqual(m.map(\.slot),[1,2,3,4]); XCTAssertEqual(m.map(\.mapping),[.grouped,.identity,.grouped,.grouped])
        let tight=DeskMapper.map(groups,target:Array(target.prefix(2)))
        XCTAssertEqual(tight.map(\.slot),[1,2,nil,nil],"never two groups on one desk, never overflow onto the last")
    }
    func testDeskMapperKeepsOrderAfterAnIdentityAnchor() {
        let target=[Space(id:1,displayToken:"x"),Space(id:2,displayToken:"x"),Space(id:3,displayToken:"x")]
        // Group "a" (ordinal 1) is anchored on desk 3; "b" (ordinal 2) must come after it, so it needs a new desk.
        let m=DeskMapper.map([DeskMapper.Group(key:"a",ordinal:1,desk:DeskRef(id:3,uuid:nil),windows:1),DeskMapper.Group(key:"b",ordinal:2,desk:DeskRef(id:50,uuid:nil),windows:1)],target:target)
        XCTAssertEqual(m.map(\.slot),[3,nil])
    }

    // MARK: - Records

    func testLiveCaptureKeepsSameTitledWindowsAndSkipsMinimized() throws {
        var s=homeBefore()
        s.windows.append(w("3711:30000",ag,"project-a — Antigravity",space:255,homeFrame))
        s.windows.append(w("3711:30001",ag,"min — Antigravity",space:255,homeFrame,minimized:true))
        let rec=try XCTUnwrap(LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:s,browserProfiles:profiles))
        XCTAssertEqual(rec.windows.filter{ $0.selector.title=="project-a — Antigravity" }.count,2)
        XCTAssertFalse(rec.windows.contains{ $0.runtime?.token=="3711:30001" })
        XCTAssertEqual(rec.windows.first{ $0.runtime?.token=="9001:514" }?.browserProfile,"Profile 1")
        XCTAssertEqual(rec.windows.first?.desktopUUID,"U-255")
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at:url) }
        try LiveRecordStore.save(rec,to:url)
        XCTAssertEqual(LiveRecordStore.load(from:url),rec)
        XCTAssertTrue(rec.sameContent(LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:s,browserProfiles:profiles,at:Date())!))
    }
    // MARK: - log noise and incomplete scans (seen live 10/19 14:28–14:32)

    func cap(_ s: Snapshot) -> LiveLayoutRecord { LiveLayoutRecord.capture(key:"k",monitor:.sharedExternal,displayToken:"home",snapshot:s,browserProfiles:profiles)! }
    func testTitleOrFrameOnlyChangesAreNotStructural() {
        let base=homeBefore(); var renamed=base
        renamed.windows[0].selector.title="queue-tool (2) — Antigravity"; renamed.windows[1].frame=Rect(-204,-1050,960,526)
        renamed.windows.append(w("2634:255","com.example.db","db",space:3,builtInFrame))
        var renamedAgain=renamed; renamedAgain.windows[6].selector.title="db — query"
        let a=cap(base),b=cap(renamed),c=cap(renamedAgain)
        XCTAssertEqual(b.structuralChanges(from:a),["+elsewhere com.example.db 2634:255"])
        XCTAssertEqual(c.structuralChanges(from:b),[])            // titles only: no log line
        XCTAssertFalse(c.sameContent(b))                            // but the file is still updated
        XCTAssertEqual(cap(homeReplugged(base)).structuralChanges(from:a).first,"desks [259,6,255,254,141]→[315,255,254,141]")
        var moved=base; moved.windows[4].spaceIDs=[141]
        XCTAssertEqual(cap(moved).structuralChanges(from:a),["com.google.Chrome 9001:514 desk 254→141"])
        var closed=base; closed.windows.removeLast()
        XCTAssertEqual(cap(closed).structuralChanges(from:a),["-com.google.Chrome 9001:437 desk 141"])
        XCTAssertEqual(a.structuralChanges(from:nil),["first record"])
    }
    func testWindowTheScanCouldNotReadButStillExistsKeepsItsEntry() {
        var withDB=homeBefore(); withDB.windows.append(w("2634:255","com.example.db","db",space:3,builtInFrame))
        let previous=cap(withDB)
        // Next scan: the Chrome window on a hidden desk and the built-in window were not resolved in time.
        var partial=withDB; partial.windows.removeAll{ ["9001:437","2634:255"].contains($0.token) }
        let all=Set(withDB.windows.map(\.token))
        let (r,carried)=cap(partial).carryingForward(previous,seenTokens:Set(partial.windows.map(\.token)),existingTokens:all)
        XCTAssertEqual(Set(carried),["9001:437","2634:255"])
        XCTAssertEqual(r.structuralChanges(from:previous),[])       // no 4↔5 flicker
        XCTAssertEqual(r.windows.first{ $0.runtime?.token=="9001:437" }?.desktopID,141)
        XCTAssertEqual(r.windows.map{ $0.desktopIndex ?? 0 },r.windows.map{ $0.desktopIndex ?? 0 }.sorted())
        // Closed (the window server no longer lists it): gone.
        let gone=cap(partial).carryingForward(previous,seenTokens:Set(partial.windows.map(\.token)),existingTokens:all.subtracting(["9001:437"]))
        XCTAssertEqual(gone.carried,["2634:255"])
        // Seen by the scan but now minimized: the scan wins, nothing carried.
        var minimized=withDB; minimized.windows[5].minimized=true
        XCTAssertEqual(cap(minimized).carryingForward(previous,seenTokens:Set(minimized.windows.map(\.token)),existingTokens:all).carried,[])
        // Its desk is gone: not carried. Unknown window server state, frozen or other-key record: nothing carried.
        let replugged=homeReplugged(partial)
        XCTAssertFalse(cap(replugged).carryingForward(previous,seenTokens:Set(partial.windows.map(\.token)),existingTokens:all).carried.contains("9001:514"))
        XCTAssertEqual(cap(partial).carryingForward(previous,seenTokens:[],existingTokens:nil).carried,[])
        XCTAssertEqual(cap(partial).carryingForward(previous.freezing(ceiling:1,at:freezeAt),seenTokens:[],existingTokens:all).carried,[])
    }
    func testWindowSeenWithoutADeskIsUnknownNotGoneAndRemovalsSayWhy() {
        let base=homeBefore(), previous=cap(base), all=Set(base.windows.map(\.token))
        // The system reported no desk for a window (suspected for 10/19 14:40:18, during a desk switch).
        var mid=base; mid.windows[5].spaceIDs=[]
        XCTAssertEqual(LiveLayoutRecord.unplacedTokens(mid),["9001:437"])
        let seen=Set(mid.windows.map(\.token)).subtracting(LiveLayoutRecord.unplacedTokens(mid))
        let (r,carried)=cap(mid).carryingForward(previous,seenTokens:seen,existingTokens:all)
        XCTAssertEqual(carried,["9001:437"]); XCTAssertEqual(r.structuralChanges(from:previous),[])
        // Minimized is a real state: it leaves the record, and the log line says why.
        var mini=base; mini.windows[5].minimized=true
        let why=LiveLayoutRecord.absenceReasons(mini)
        XCTAssertEqual(LiveLayoutRecord.unplacedTokens(mini),[])
        XCTAssertEqual(cap(mini).structuralChanges(from:previous,why:why),["-com.google.Chrome 9001:437 desk 141 (minimized)"])
    }
    func testSavedWindowWithoutDeskIdentityStillDecodesAndNewFieldsRoundTrip() throws {
        var sv=saved(ag,"x",slot:2); sv.desktopID=255; sv.desktopUUID="U-255"
        let data=try JSONEncoder().encode(sv)
        XCTAssertEqual(try JSONDecoder().decode(SavedWindow.self,from:data),sv)
        var dict=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        dict.removeValue(forKey:"desktopID"); dict.removeValue(forKey:"desktopUUID")
        let old=try JSONDecoder().decode(SavedWindow.self,from:JSONSerialization.data(withJSONObject:dict))
        XCTAssertNil(old.desktopID); XCTAssertEqual(old.groupKey,"l:组-2")
        // The record stays schema 1 so 0.6.8 still loads a layout saved by 0.6.9 (it ignores unknown keys).
        XCTAssertEqual(sharedRecord([sv]).schemaVersion,1)
    }
}

final class MissionControlOpeningTests: XCTestCase {
    func testOpeningTriesAppThenShortcutThenAppWithGrowingWaits() {
        let a=MissionControlOpening.attempts(ctrlUpEnabled:true)
        XCTAssertEqual(a.map(\.method),[.app,.shortcut,.app])
        XCTAssertEqual(a.map(\.wait),a.map(\.wait).sorted())
        XCTAssertEqual(MissionControlOpening.attempts(ctrlUpEnabled:false).map(\.method),[.app,.app,.app])
        XCTAssertLessThan(MissionControlOpening.backoff(after:0),MissionControlOpening.backoff(after:1))
        // Opening (≤ ~11.5 s with pauses) must fit before the add budget starts, not eat into it.
        XCTAssertLessThan(a.map(\.wait).reduce(0,+)+MissionControlOpening.backoff(after:0)+MissionControlOpening.backoff(after:1),AutoSpaces.runTimeout)
    }
    func testFailureTextSaysWhatWasTried() {
        let t=MissionControlOpening.failureText(tried:[.app,.shortcut,.app],ctrlUpEnabled:true)
        XCTAssertTrue(t.contains("3"),t); XCTAssertTrue(t.contains("⌃↑"),t)
        XCTAssertTrue(MissionControlOpening.failureText(tried:[.app,.app,.app],ctrlUpEnabled:false).contains("已关闭"))
    }
}

final class VolumeKeyRoutingTests: XCTestCase {
    func testVolumeKeysAlwaysGoToTheSystemOutputNeverDDC() {
        for key in [MediaKey.volumeUp,.volumeDown] {
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:true,outputVolumeSettable:true,outputMuteSettable:false),.systemOutput)
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:true,outputVolumeSettable:false,outputMuteSettable:true),.passThrough)
            XCTAssertEqual(VolumeKeyRouting.route(key,enabled:false,outputVolumeSettable:true,outputMuteSettable:true),.passThrough)
        }
        XCTAssertEqual(VolumeKeyRouting.route(.mute,enabled:true,outputVolumeSettable:false,outputMuteSettable:true),.systemOutput)
        XCTAssertEqual(VolumeKeyRouting.route(.mute,enabled:true,outputVolumeSettable:true,outputMuteSettable:false),.passThrough)
    }
    func testVolumeStepsAreThreePercent() {
        XCTAssertEqual(BrightnessStep.next(0.51,up:true,fine:false,coarse:BrightnessStep.volumeCoarse),0.54,accuracy:0.0001)
        XCTAssertEqual(BrightnessStep.next(0.51,up:false,fine:false,coarse:BrightnessStep.volumeCoarse),0.48,accuracy:0.0001)
        XCTAssertEqual(DDCPacket.brightness,0x10)
    }
}
