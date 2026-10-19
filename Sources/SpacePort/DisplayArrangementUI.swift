// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

/// A switch waiting for 「保留这个排列？」. The preview is app-scoped: macOS itself undoes it if LayoutKeeper quits or
/// crashes, so doing nothing (or a crash) always ends in the old arrangement.
struct ArrangementPreview {
    var presetID: String
    var name: String
    var detail: String
    var targets: [ArrangementTarget]
    var rollback: [ArrangementTarget]
    var displays: Set<UInt32>
    var scope: DisplayArrangementIO.Scope
    var deadline: Date
}

extension Model {
    static let arrangementConfirmSeconds: TimeInterval=15

    func liveDisplays() -> [LiveDisplay] { RenderMode.snapshot ? snapshotDisplays : DisplayArrangementIO.live() }
    static func currentDisplayIDs() -> Set<UInt32> {
        Set(NSScreen.screens.compactMap{ ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
    }
    /// Why no switch can start right now (nil = it can).
    func arrangementBusyReason() -> String? {
        if arrangementPreview != nil { return lk("正在确认上一次切换") }
        if busy { return lk("正在处理上一个操作") }
        if attachInProgress() { return lk("正在恢复窗口，稍后再试") }
        return nil
    }
    func arrangementMenu() -> ArrangementMenu? {
        ArrangementMenu.build(presets:arrangementPresets,live:liveDisplays(),busy:arrangementBusyReason(),hotkeysEnabled:hotkeySettings.enabled)
    }
    static func describe(_ live: [LiveDisplay]) -> String {
        live.sorted{ $0.id<$1.id }.map{ "\($0.key)\($0.isMain ? "*" : ""):(\($0.x),\($0.y) \($0.width)x\($0.height))" }.joined(separator:" ")
    }
    static func describe(_ targets: [ArrangementTarget]) -> String { targets.map{ "\($0.key):(\($0.x),\($0.y))" }.joined(separator:" ") }
    /// Preset names are typed by the user: the log carries a short hash only.
    static func logName(_ p: ArrangementPreset) -> String { p.id.hasPrefix("quick-") ? p.id : "p:\(p.id.prefix(8)) n:\(RestoreLog.hash(p.name))" }
    static func logID(_ id: String) -> String { id.hasPrefix("quick-") ? id : "p:\(id.prefix(8))" }

    // MARK: Save, rename, delete

    func saveCurrentArrangement() {
        if let why=arrangementBusyReason() { notify?(UserNotice(title:lk("没有保存排列"),detail:why,duration:4)); return }
        let live=liveDisplays()
        switch ArrangementGeometry.capture(live,id:UUID().uuidString,name:"",at:Date()) {
        case .failure(let e):
            logRestore("arrangement: save refused reason=\(e.code) displays=[\(Self.describe(live))]")
            notify?(UserNotice(title:lk("没有保存排列"),detail:e.message,duration:4))
        case .success(let preset):
            savePreset(preset,suggested:ArrangementGeometry.suggestedName(preset),title:lk("把当前排列存为"),source:"current",live:live)
        }
    }
    /// Save 「外接屏在 edge，anchor」 without applying it (nothing on screen changes).
    func saveQuickArrangement(edge: ArrangementEdge,anchor: ArrangementAnchor) {
        if let why=arrangementBusyReason() { notify?(UserNotice(title:lk("没有保存排列"),detail:why,duration:4)); return }
        let live=liveDisplays()
        switch ArrangementGeometry.quickPreset(live,edge:edge,anchor:anchor,id:UUID().uuidString,at:Date()) {
        case .failure(let e):
            logRestore("arrangement: save refused source=quick edge=\(edge.rawValue)/\(anchor.rawValue) reason=\(e.code) displays=[\(Self.describe(live))]")
            notify?(UserNotice(title:lk("没有保存排列"),detail:e.message,duration:4))
        case .success(let preset):
            savePreset(preset,suggested:preset.name,title:lk("存为排列"),source:"quick \(edge.rawValue)/\(anchor.rawValue)",live:live)
        }
    }
    private func savePreset(_ draft: ArrangementPreset,suggested: String,title: String,source: String,live: [LiveDisplay]) {
        var preset=draft
        if let same=arrangementPresets.first(where:{ ArrangementGeometry.sameArrangement($0,preset) }) {
            logRestore("arrangement: save skipped source=\(source), same as \(Self.logName(same))")
            notify?(UserNotice(title:lk("这个排列已经存过"),detail:lk("就是「%@」", "\(same.name)"),duration:4)); return
        }
        let taken=Set(arrangementPresets.map(\.name))
        var name=suggested, n=2
        while taken.contains(name) { name="\(suggested) \(n)"; n+=1 }
        guard let chosen=Self.askName(title:title,message:ArrangementGeometry.describe(preset),initial:name) else { return }
        preset.name=chosen
        arrangementPresets.append(preset)
        logRestore("arrangement: saved \(Self.logName(preset)) source=\(source) displays=[\(Self.describe(live))] relations=\(preset.displays.compactMap{ d in d.relation.map{ "\(d.key)->\($0.parent):\($0.edge.rawValue)/\($0.anchor.rawValue)\($0.offset >= 0 ? "+" : "")\($0.offset)" } })")
        notify?(UserNotice(title:lk("已保存排列「%@」", "\(chosen)"),detail:lk("在菜单栏「显示器排列」里一键切换"),duration:4))
    }
    /// Small modal name prompt (the app has no document windows to hang a sheet on). nil = cancelled.
    static func askName(title: String,message: String,initial: String) -> String? {
        let alert=NSAlert(); alert.messageText=title; alert.informativeText=message
        let field=NSTextField(frame:NSRect(x:0,y:0,width:260,height:24)); field.stringValue=initial
        alert.accessoryView=field
        alert.addButton(withTitle:lk("保存")); alert.addButton(withTitle:lk("取消"))
        NSApplication.shared.activate(ignoringOtherApps:true)
        alert.window.initialFirstResponder=field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        return name.isEmpty ? initial : name
    }
    func renameArrangement(_ id: String,to name: String) {
        let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty,let i=arrangementPresets.firstIndex(where:{ $0.id==id }),arrangementPresets[i].name != clean else { return }
        arrangementPresets[i].name=clean
        logRestore("arrangement: renamed \(Self.logName(arrangementPresets[i]))")
    }
    func deleteArrangement(_ id: String) {
        guard let i=arrangementPresets.firstIndex(where:{ $0.id==id }) else { return }
        let p=arrangementPresets.remove(at:i)
        logRestore("arrangement: deleted \(Self.logName(p))")
    }

    // MARK: Apply → confirm → keep / revert

    func applyArrangement(_ id: String,source: String) {
        guard let preset=arrangementPresets.first(where:{ $0.id==id }) else { return }
        applyArrangement(preset:preset,source:source)
    }
    /// 「外接屏在上方」 etc. from the menu or the settings picker: built from the sizes connected now, not saved.
    func applyQuickArrangement(edge: ArrangementEdge,anchor: ArrangementAnchor = .center,source: String) {
        let live=liveDisplays()
        let id="quick-\(edge.rawValue)-\(anchor.rawValue)"
        switch ArrangementGeometry.quickPreset(live,edge:edge,anchor:anchor,id:id,at:Date()) {
        case .failure(let e):
            logRestore("arrangement: apply quick \(edge.rawValue)/\(anchor.rawValue) source=\(source) refused reason=\(e.code) displays=[\(Self.describe(live))]")
            notify?(UserNotice(title:lk("没有切换到「%@」", "\(ArrangementGeometry.quickName(edge:edge,anchor:anchor))"),detail:e.message,duration:4))
        case .success(let preset): applyArrangement(preset:preset,source:source)
        }
    }
    func applyArrangement(preset: ArrangementPreset,source: String) {
        let tag="arrangement: apply \(Self.logName(preset)) source=\(source)"
        if let why=arrangementBusyReason() {
            logRestore("\(tag) refused reason=busy (\(why))")
            notify?(UserNotice(title:lk("没有切换到「%@」", "\(preset.name)"),detail:why,duration:4)); return
        }
        let live=liveDisplays()
        let plan: ArrangementPlan
        switch ArrangementGeometry.plan(preset,live) {
        case .failure(let e):
            logRestore("\(tag) refused reason=\(e.code) displays=[\(Self.describe(live))]")
            notify?(UserNotice(title:lk("没有切换到「%@」", "\(preset.name)"),detail:e.message,duration:4)); return
        case .success(let p): plan=p
        }
        if plan.alreadyApplied {
            // Nothing to write: no reconfiguration, no flicker, no confirmation.
            logRestore("\(tag) skipped: already arranged like this displays=[\(Self.describe(live))]")
            notify?(UserNotice(title:lk("已经是「%@」", "\(preset.name)"),duration:3)); return
        }
        let rollback=live.map{ ArrangementTarget(id:$0.id,key:$0.key,x:$0.x,y:$0.y) }
        let ids=Set(live.map(\.id))
        arrangementGuard.begin(displays:ids,label:preset.id)
        var scope=DisplayArrangementIO.Scope.appOnly
        var outcome=DisplayArrangementIO.apply(plan.targets,scope:scope)
        if !outcome.ok,outcome.error != .failure,outcome.error != .cannotComplete {
            // Not expected. A session preview still reverts on the timeout; only a crash would not undo it.
            logRestore("\(tag) app-only preview refused error=\(outcome.error!.rawValue); trying a session preview")
            scope = .session
            outcome=DisplayArrangementIO.apply(plan.targets,scope:scope)
        }
        arrangementGuard.end(at:Date())
        logRestore("\(tag) preview scope=\(scope.rawValue) resolvedFromRelations=\(plan.resolved) from=[\(Self.describe(live))] to=[\(Self.describe(plan.targets))] result=\(outcome.ok ? "ok" : "error \(outcome.error!.rawValue)") attempts=\(outcome.attempts) adjustedByWindowServer=\(outcome.adjusted)")
        guard outcome.ok else {
            notify?(UserNotice(title:lk("没有切换到「%@」", "\(preset.name)"),detail:lk("macOS 拒绝了这次排列（错误 %@），屏幕没有变化", "\(outcome.error!.rawValue)"),duration:5)); return
        }
        let preview=ArrangementPreview(presetID:preset.id,name:preset.name,detail:ArrangementGeometry.describe(preset),targets:plan.targets,rollback:rollback,
                                       displays:ids,scope:scope,deadline:Date()+Self.arrangementConfirmSeconds)
        arrangementPreview=preview
        arrangementTimer?.invalidate()
        let t=Timer(timeInterval:Self.arrangementConfirmSeconds,repeats:false) { [weak self] _ in self?.revertArrangement(reason:"timeout") }
        arrangementTimer=t; RunLoop.main.add(t,forMode:.common)
        showArrangementConfirm?(preview)
    }
    /// 「保留」: write the same origins permanently (what System Settings stores).
    func keepArrangement() {
        guard let p=arrangementPreview else { return }
        finishPreview()
        arrangementGuard.begin(displays:p.displays,label:p.presetID)
        let o=DisplayArrangementIO.apply(p.targets,scope:.permanent)
        arrangementGuard.end(at:Date())
        logRestore("arrangement: kept \(Self.logID(p.presetID)) permanent result=\(o.ok ? "ok" : "error \(o.error!.rawValue)") attempts=\(o.attempts) adjustedByWindowServer=\(o.adjusted)")
        if !o.ok {
            // The app-only preview would be undone at quit: say so instead of pretending it was kept.
            notify?(UserNotice(title:lk("排列没能保存"),detail:lk("macOS 拒绝写入（错误 %@）。现在的排列在退出 LayoutKeeper 后会变回原样。", "\(o.error!.rawValue)"),duration:0))
        }
    }
    /// 「还原」, ×, Esc, the 15 s timeout, sleep: back to the arrangement before the switch.
    func revertArrangement(reason: String) {
        guard let p=arrangementPreview else { return }
        finishPreview()
        let online=Set(liveDisplays().map(\.id))
        arrangementGuard.begin(displays:p.displays,label:p.presetID)
        var line="arrangement: reverted \(Self.logID(p.presetID)) reason=\(reason)"
        if p.rollback.allSatisfy({ online.contains($0.id) }) {
            let o=DisplayArrangementIO.apply(p.rollback,scope:p.scope)
            line+=" result=\(o.ok ? "ok" : "error \(o.error!.rawValue)") to=[\(Self.describe(p.rollback))] adjustedByWindowServer=\(o.adjusted)"
            if !o.ok { DisplayArrangementIO.restorePermanent(); line+=" fallback=restore-permanent" }
        } else {
            DisplayArrangementIO.restorePermanent(); line+=" displays-changed fallback=restore-permanent"
        }
        arrangementGuard.end(at:Date())
        logRestore(line)
    }
    private func finishPreview() {
        arrangementTimer?.invalidate(); arrangementTimer=nil
        arrangementPreview=nil
        hideArrangementConfirm?()
    }
    /// LayoutKeeper's own arrangement change (same displays, inside the guard): not a plug-in, wake or unplug.
    func ownArrangementChange() -> Bool { arrangementGuard.covers(Self.currentDisplayIDs(),at:Date()) }
    /// A screen event during the confirmation that is not our own: a display came or went. Never commit then.
    func arrangementScreensChanged() {
        guard let p=arrangementPreview,!ownArrangementChange(),Self.currentDisplayIDs() != p.displays else { return }
        revertArrangement(reason:"displays-changed")
    }
}

/// 「保留这个排列？」 with a countdown that defaults to reverting. × top-left (like every notice), Esc = 还原,
/// Return = 保留. Shown on the main display, where the menu bar is after the switch.
final class ArrangementConfirmPanel {
    private var panel: NSPanel?
    func show(_ preview: ArrangementPreview,keep: @escaping () -> Void,revert: @escaping () -> Void) {
        close()
        let p=KeyablePanel(contentRect:NSRect(x:0,y:0,width:380,height:150),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isFloatingPanel=true; p.level = .statusBar; p.hidesOnDeactivate=false; p.isReleasedWhenClosed=false
        p.backgroundColor = .clear; p.isOpaque=false; p.hasShadow=true
        p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        let hosting=NSHostingView(rootView:ArrangementConfirmView(name:preview.name,detail:preview.detail,deadline:preview.deadline,total:Model.arrangementConfirmSeconds,keep:keep,revert:revert))
        p.contentView=hosting; p.setContentSize(hosting.fittingSize)
        if let screen=NSScreen.screens.first {
            let v=screen.visibleFrame
            p.setFrameOrigin(NSPoint(x:v.midX-p.frame.width/2,y:v.maxY-p.frame.height-80))
        }
        NSApplication.shared.activate(ignoringOtherApps:true)
        p.makeKeyAndOrderFront(nil); panel=p
    }
    func close() { panel?.close(); panel=nil }
}
private final class KeyablePanel: NSPanel { override var canBecomeKey: Bool { true } }

struct ArrangementConfirmView: View {
    let name: String
    let detail: String
    let deadline: Date
    let total: TimeInterval
    let keep: () -> Void
    let revert: () -> Void
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.25)) { context in
            let left=max(0,deadline.timeIntervalSince(context.date))
            VStack(alignment:.leading,spacing:8) {
                Text(lk("保留这个排列？")).font(.headline)
                Text(lk("已切换到「%@」：%@", "\(name)", "\(detail)")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                ProgressView(value:left,total:total).progressViewStyle(.linear)
                HStack {
                    Text(lk("%@ 秒后自动还原", "\(Int(left.rounded(.up)))")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button(lk("还原"),action:revert).keyboardShortcut(.cancelAction)
                    Button(lk("保留"),action:keep).primaryButton().keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.leading,30).padding(.trailing,16).padding(.vertical,14)
        .frame(width:380)
        .background(ArrangementPanelBackground())
        .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).strokeBorder(Color.primary.opacity(0.08)))
        .overlay(alignment:.topLeading) {
            Button(action:revert) {
                Image(systemName:"xmark").font(.system(size:9,weight:.bold)).foregroundStyle(.secondary)
                    .frame(width:18,height:18).background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain).padding(5).help(lk("还原")).accessibilityLabel(lk("还原"))
        }
    }
}
struct ArrangementPanelBackground: View {
    var body: some View {
        if RenderMode.snapshot { Color(nsColor:.windowBackgroundColor) } else { ArrangementPanelEffect() }
    }
}
struct ArrangementPanelEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v=NSVisualEffectView(); v.material = .popover; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Settings → 显示器 → 显示器排列: rename, delete, per-preset hotkey, switch.
struct ArrangementSettingsSection: View {
    @ObservedObject var model: Model
    @State private var live: [LiveDisplay]=[]
    @State private var confirmDelete: ArrangementPreset?
    var body: some View {
        Section(lk("显示器排列")) {
            Text(lk("选好外接屏放在 MacBook 屏幕的哪一边、怎么对齐，点「切换」立即生效；15 秒内点「保留」才会留下，不点就自动还原。常用的摆法可以存成排列，在菜单栏「显示器排列」里一键切换。只改屏幕的相对位置，不改分辨率和主屏幕，也不会触发窗口恢复。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            QuickArrangementPicker(model:model,live:live)
            ForEach(model.arrangementPresets) { preset in
                ArrangementRow(model:model,preset:preset,status:ArrangementGeometry.status(preset,live),delete:{ confirmDelete=preset })
            }
            HStack {
                Button(lk("把当前排列存为…")) { model.saveCurrentArrangement(); reload() }
                    .disabled(saveBlock != nil)
                if let why=saveBlock { Text(why).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(lk("刷新")) { reload() }.controlSize(.small)
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didChangeScreenParametersNotification)) { _ in DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { reload() } }
        .onChange(of:model.arrangementPreview == nil) { _,_ in reload() }
        .alert(lk("删除这个排列？"),isPresented:Binding(get:{ confirmDelete != nil },set:{ if !$0 { confirmDelete=nil } }),presenting:confirmDelete) { p in
            Button(lk("删除"),role:.destructive) { model.deleteArrangement(p.id) }
            Button(lk("取消"),role:.cancel) {}
        } message: { p in Text(lk("「%@」只是一条记录，删掉不会改变现在的屏幕排列。", "\(p.name)")) }
    }
    private var saveBlock: String? {
        if let why=model.arrangementBusyReason() { return why }
        if case .failure(let e)=ArrangementGeometry.capture(live,id:"",name:"",at:Date()) { return e.message }
        return nil
    }
    private func reload() { live=model.liveDisplays() }
}

struct ArrangementRow: View {
    @ObservedObject var model: Model
    let preset: ArrangementPreset
    let status: ArrangementGeometry.Status
    let delete: () -> Void
    @State private var name=""
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                TextField("",text:$name,prompt:Text(lk("名称"))).labelsHidden().multilineTextAlignment(.leading)
                    .textFieldStyle(.plain).font(.body.weight(.medium)).frame(maxWidth:220,alignment:.leading)
                    .onSubmit { model.renameArrangement(preset.id,to:name) }
                Spacer()
                pill
                PresetHotkeyButton(model:model,preset:preset)
                Button(lk("切换")) { model.applyArrangement(preset.id,source:"settings") }.controlSize(.small).disabled(!canApply)
                Button(action:delete) { Image(systemName:"trash") }.buttonStyle(.borderless).help(lk("删除"))
            }
            Text(ArrangementGeometry.describe(preset)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let message=model.arrangementHotkeyStatus[preset.id]?.message {
                Label(message,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(Tone.warning.color)
            }
        }
        .onAppear { name=preset.name }
        .onChange(of:preset.name) { _,v in name=v }
        .onDisappear { if name != preset.name { model.renameArrangement(preset.id,to:name) } }
    }
    private var canApply: Bool {
        if case .applicable(let active)=status { return !active && model.arrangementBusyReason() == nil }
        return false
    }
    @ViewBuilder private var pill: some View {
        switch status {
        case .applicable(true): Pill(text:lk("当前"),tone:.success)
        case .applicable(false): Pill(text:lk("可切换"),tone:.info)
        case .blocked(let e): Pill(text:lk("暂不可用"),tone:.warning).help(e.message)
        case .otherDisplays(let e): Pill(text:lk("别的屏幕"),tone:.neutral).help(e.message)
        }
    }
}

/// Same recorder as the action hotkeys: click, press the combination, Esc cancels. Global hotkeys are suspended
/// while recording so the old combination can't fire.
struct PresetHotkeyButton: View {
    @ObservedObject var model: Model
    let preset: ArrangementPreset
    @State private var monitor: Any?
    var recording: Bool { model.recordingPresetHotkey == preset.id }
    var body: some View {
        HStack(spacing:2) {
            Button(recording ? lk("按下快捷键…") : (preset.hotkey?.display ?? lk("快捷键"))) { recording ? stop() : start() }
                .controlSize(.small).disabled(!model.hotkeySettings.enabled)
            if preset.hotkey != nil {
                Button { set(nil) } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help(lk("清除")).disabled(!model.hotkeySettings.enabled)
            }
        }
        .onDisappear { if recording { stop() } }
    }
    private func set(_ key: Hotkey?) {
        guard let i=model.arrangementPresets.firstIndex(where:{ $0.id==preset.id }) else { return }
        model.arrangementPresets[i].hotkey=key   // re-registers every hotkey and reports conflicts
    }
    private func start() {
        model.recordingPresetHotkey=preset.id; model.suspendHotkeys?(true)
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            var mods=HotkeyModifiers()
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.option) { mods.insert(.option) }
            if event.modifierFlags.contains(.control) { mods.insert(.control) }
            if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
            let key=Hotkey(keyCode:UInt32(event.keyCode),modifiers:mods)
            if HotkeyRegistrar.validate(key) != nil { NSSound.beep(); return nil }
            stop(apply:false); set(key)
            return nil
        }
    }
    private func stop(apply: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor=nil; model.recordingPresetHotkey=nil
        if apply { model.suspendHotkeys?(false) }
    }
}

/// Settings: pick the edge and alignment of the external monitor, then 切换 (preview → 保留) or 存为排列.
struct QuickArrangementPicker: View {
    @ObservedObject var model: Model
    let live: [LiveDisplay]
    @State private var edge: ArrangementEdge = .above
    @State private var anchor: ArrangementAnchor = .center
    @State private var seeded=false
    var body: some View {
        let pair=ArrangementGeometry.pair(live)
        let block: String?={ if case .failure(let e)=pair { return e.message }; return model.arrangementBusyReason() }()
        let current: Bool={
            guard case .success(let p)=ArrangementGeometry.quickPreset(live,edge:edge,anchor:anchor,id:"",at:Date()),
                  case .success(let plan)=ArrangementGeometry.plan(p,live) else { return false }
            return plan.alreadyApplied
        }()
        HStack(alignment:.center,spacing:18) {
            ArrangementSchematic(live:live,edge:edge,anchor:anchor).frame(width:150,height:104)
            VStack(alignment:.leading,spacing:10) {
                Grid(alignment:.leading,horizontalSpacing:10,verticalSpacing:8) {
                    GridRow {
                        Text(lk("外接屏在")).foregroundStyle(.secondary)
                        Picker("",selection:$edge) {
                            ForEach(ArrangementGeometry.quickEdges,id:\.self) { Text(ArrangementGeometry.edgeLabel($0)).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width:240)
                    }
                    GridRow {
                        Text(lk("对齐")).foregroundStyle(.secondary)
                        Picker("",selection:$anchor) {
                            ForEach([ArrangementAnchor.start,.center,.end],id:\.self) { Text(ArrangementGeometry.alignmentLabel(edge:edge,anchor:$0)).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width:240)
                    }
                }
                HStack(spacing:8) {
                    if let block { Text(block).font(.caption).foregroundStyle(.secondary) }
                    else if current { Text(lk("现在就是这样排的")).font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength:0)
                    Button(lk("存为排列…")) { model.saveQuickArrangement(edge:edge,anchor:anchor) }.disabled(block != nil)
                    Button(lk("切换")) { model.applyQuickArrangement(edge:edge,anchor:anchor,source:"settings") }.primaryButton().disabled(block != nil || current)
                }
            }
        }
        .padding(.vertical,4)
        .onAppear { seed() }
        .onChange(of:live) { _,_ in seed() }
    }
    /// Start from how the displays sit now (once), so 切换 is a deliberate change.
    private func seed() {
        guard !seeded,let e=ArrangementGeometry.currentEdge(live) else { return }
        seeded=true; edge=e; anchor=ArrangementGeometry.currentAnchor(live) ?? .center
    }
}

/// Two rectangles to scale: the MacBook screen and the external monitor in the picked place; the menu bar marks main.
struct ArrangementSchematic: View {
    let live: [LiveDisplay]
    let edge: ArrangementEdge
    let anchor: ArrangementAnchor
    var body: some View {
        GeometryReader { geo in
            let (b,e)=displays
            let f=frames(in:geo.size,b,e)
            ZStack(alignment:.topLeading) {
                screen(f.builtIn,title:"MacBook",main:b.isMain,highlight:false)
                screen(f.external,title:lk("外接屏"),main:e.isMain,highlight:true)
            }
            .animation(.easeInOut(duration:0.2),value:edge).animation(.easeInOut(duration:0.2),value:anchor)
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(ArrangementGeometry.quickName(edge:edge,anchor:anchor))
    }
    private func frames(in size: CGSize,_ b: LiveDisplay,_ e: LiveDisplay) -> (builtIn: CGRect,external: CGRect) {
        let r=ArrangementGeometry.quickRects(builtIn:b,external:e,edge:edge,anchor:anchor)
        let minX=min(r.builtIn.x,r.external.x), minY=min(r.builtIn.y,r.external.y)
        let w=max(r.builtIn.x+r.builtIn.width,r.external.x+r.external.width)-minX
        let h=max(r.builtIn.y+r.builtIn.height,r.external.y+r.external.height)-minY
        let scale=min(size.width/CGFloat(w),size.height/CGFloat(h))
        let dx=(size.width-CGFloat(w)*scale)/2, dy=(size.height-CGFloat(h)*scale)/2
        func frame(_ x: IntRect) -> CGRect {
            CGRect(x:dx+CGFloat(x.x-minX)*scale,y:dy+CGFloat(x.y-minY)*scale,width:CGFloat(x.width)*scale,height:CGFloat(x.height)*scale).insetBy(dx:1,dy:1)
        }
        return (frame(r.builtIn),frame(r.external))
    }
    /// The real pair, or sample sizes when it isn't connected (the picker is disabled then).
    private var displays: (LiveDisplay,LiveDisplay) {
        if case .success(let p)=ArrangementGeometry.pair(live) { return (p.builtIn,p.external) }
        return (LiveDisplay(id:1,key:"builtin",uuid:"",name:"",builtIn:true,isMain:true,x:0,y:0,width:1512,height:982),
                LiveDisplay(id:2,key:"",uuid:"",name:"",builtIn:false,isMain:false,x:0,y:0,width:1920,height:1080))
    }
    private func screen(_ f: CGRect,title: String,main: Bool,highlight: Bool) -> some View {
        RoundedRectangle(cornerRadius:4,style:.continuous)
            .fill(highlight ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius:4,style:.continuous).strokeBorder(highlight ? Color.accentColor : Color.primary.opacity(0.35),lineWidth:1))
            .overlay(alignment:.top) { if main { Rectangle().fill(Color.primary.opacity(0.35)).frame(height:3).padding(.horizontal,3).padding(.top,3) } }
            .overlay { Text(title).font(.system(size:10,weight:.medium)).foregroundStyle(highlight ? Color.accentColor : .secondary).lineLimit(1).minimumScaleFactor(0.6).padding(2) }
            .frame(width:f.width,height:f.height)
            .offset(x:f.minX,y:f.minY)
    }
}
