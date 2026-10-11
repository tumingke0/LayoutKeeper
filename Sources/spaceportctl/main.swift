// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

let command=CommandLine.arguments.dropFirst().first ?? "help"
switch command {
case "diagnose":
    _ = NSApplication.shared
    let backend=ReadOnlySpaces()
    print(MacEnvironment.json(MacEnvironment.diagnostics(spaces:backend)))
case "capture-coverage":
    // Read only: no permission prompt, no window writes, no Space switches. Window IDs are printed to stdout only.
    _ = NSApplication.shared
    let backend=ReadOnlySpaces()
    let apps=NSWorkspace.shared.runningApplications.filter{$0.activationPolicy == .regular && $0.processIdentifier != getpid()}
    var bundleByPID=[Int32:String]()
    for app in apps { if let id=app.bundleIdentifier {bundleByPID[app.processIdentifier]=id} }
    let inventory=CGWindowInventory.collect(spaces:backend,includePIDs:Set(bundleByPID.keys))
    let displays=MacEnvironment.displays()
    let spaces=(try? backend.spaces(displays:displays)) ?? []
    var slotBySpace=[UInt64:String]()
    for display in displays {
        for (index,space) in spaces.filter({$0.displayToken==display.token && $0.kind == .ordinary}).enumerated() {slotBySpace[space.id]="\(display.role.rawValue)#\(index+1)"}
    }
    var resolved=[Int32:Set<UInt32>]()
    let trusted=AXIsProcessTrusted()
    var axStatus="not trusted: only CG candidates are listed (no prompt issued)"
    if trusted {
        let windows=AXWindows(spaces:backend)
        let external=displays.first{$0.role == .external}?.token
        if let snapshot=try? windows.scan(selectedDisplayToken:external) {
            for w in snapshot.windows { let parts=w.token.split(separator:":"); if parts.count==2,let pid=Int32(parts[0]),let id=UInt32(parts[1]) {resolved[pid,default:[]].insert(id)} }
            axStatus="trusted: AX resolved \(snapshot.windows.count) readable windows; report summary: \(windows.latestCaptureReport.summary)"
        } else { axStatus="trusted but scan failed" }
    }
    var rows=[[String:Any]]()
    for pid in Set(inventory.candidates.map(\.ownerPID)).sorted() {
        guard let bundle=bundleByPID[pid] else {continue}
        let mine=inventory.candidates.filter{$0.ownerPID==pid && $0.layer==0}
        let candidates=mine.filter{WindowCandidateRules.exclusion($0)==nil}
        var excluded=[String:Int]()
        for row in mine { if let reason=WindowCandidateRules.exclusion(row) {excluded[reason.rawValue,default:0]+=1} }
        rows.append(["bundleID":bundle,"cgCandidates":candidates.map{["windowID":$0.windowID,"slot":($0.spaceIDs?.count==1 ? slotBySpace[$0.spaceIDs![0]] : nil) ?? "other/unknown","axResolved":resolved[pid]?.contains($0.windowID) ?? false] as [String:Any]},"excludedLayerZero":excluded])
    }
    print(MacEnvironment.json(["windowServerTraitsAvailable":inventory.traitsAvailable,"accessibility":axStatus,"applications":rows]))
case "simulate", "simulate-noop":
    let backend=DemoBackend(); backend.pretendSuccess=command == "simulate-noop"
    do {
        let plan=try backend.plan()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let result=Restorer.execute(plan,windows:backend,spaces:backend,approved:true)
        print(String(data:try encoder.encode(result),encoding:.utf8)!)
        if command == "simulate" && result.contains(where:{$0.outcome != .verified}) { exit(1) }
        if command == "simulate-noop" && !result.contains(where:{$0.outcome == .failed}) { exit(1) }
    } catch { fputs("\(error)\n",stderr); exit(1) }
case "validate-profile":
    guard CommandLine.arguments.count==3 else { fputs("usage: layoutkeeperctl validate-profile path.json\n",stderr); exit(2) }
    do { let p=try ProfileStore.load(from:URL(fileURLWithPath:CommandLine.arguments[2])); print("Valid schema \(p.schemaVersion): \(p.location), \(p.windows.count) windows") }
    catch { fputs("\(error)\n",stderr); exit(1) }
default:
    print("""
    layoutkeeperctl — LayoutKeeper command-line tools (spaceportctl is a compatibility alias)
      diagnose                 Read-only system/display/Spaces/symbol diagnostic; no TCC prompts
      simulate                 In-memory cross-display restore and readback verification
      simulate-noop            Confirm a successful API no-op is reported as failure
      validate-profile FILE    Validate an existing layout JSON without mutations
      capture-coverage         Read-only per-app window candidates vs AX-resolved windows (all Spaces)
    Real window writes are available only after an explicit preview confirmation in the GUI.
    Cross-Space writes on macOS 27 are disabled pending isolated compatibility validation.
    """)
}
