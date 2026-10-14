// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

/// A shared-mode notice. Shown as a closable toast and kept in the model until dismissed or resolved.
struct SharedNotice: Equatable {
    enum Kind: Equatable { case missingSpaces(Int), migrated(Int), separateSpacesOff, multipleMonitors }
    var kind: Kind
    var title: String {
        switch kind {
        case .missingSpaces(let n): return "外接屏少 \(n) 个桌面"
        case .migrated(let n): return "\(n) 个桌面被移到了内置屏"
        case .separateSpacesOff: return "「显示器具有单独的空间」已关闭"
        case .multipleMonitors: return "接了多块外接屏，已按每块屏单独记"
        }
    }
    var detail: String {
        switch kind {
        case .missingSpaces(let n): return "多出来的窗口先放在最后一个桌面。打开调度中心，在顶部按「+」补 \(n) 个桌面，补好后会自动再恢复一次。"
        case .migrated: return "这是拔掉外接屏时 macOS 挪过来的。不需要的话，在调度中心把它们删掉即可；共用布局按桌面顺序保存，删了也不会丢，下次接上外接屏照样恢复。"
        case .separateSpacesOff: return "共用模式需要每块屏有自己的桌面。请在「系统设置 → 桌面与程序坞 → 调度中心」打开它，注销后生效。"
        case .multipleMonitors: return "共用模式只在接一块外接屏时生效。拔到只剩一块后会自动切回共用布局。"
        }
    }
    var icon: String {
        switch kind {
        case .missingSpaces: return "plus.rectangle.on.rectangle"
        case .migrated: return "rectangle.stack.badge.minus"
        case .separateSpacesOff: return "exclamationmark.triangle.fill"
        case .multipleMonitors: return "display.2"
        }
    }
    var tone: Tone { kind == .separateSpacesOff ? .warning : .info }
}

enum SeparateSpaces {
    /// `defaults read com.apple.spaces spans-displays`: 1 means "Displays have separate Spaces" is OFF. Read only.
    static var enabled: Bool { !(UserDefaults(suiteName:"com.apple.spaces")?.bool(forKey:"spans-displays") ?? false) }
}

enum MissionControl {
    static func open() {
        let url=URL(fileURLWithPath:"/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,_ in }
    }
}

extension Model {
    var sharedModeActive: Bool { currentExternalMonitor?.identity.isSharedExternal == true }
    func sharedNoticeToast(_ notice: SharedNotice) -> Toast {
        var actions=[Toast.Action]()
        switch notice.kind {
        case .missingSpaces, .migrated: actions.append(Toast.Action(title:"打开调度中心") { MissionControl.open() })
        case .separateSpacesOff: actions.append(Toast.Action(title:"打开设置") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Desktop-Settings.extension")!) })
        case .multipleMonitors: break
        }
        return Toast(icon:notice.icon,tone:notice.tone,title:notice.title,detail:notice.detail,actions:actions,duration:0) { [weak self] in
            if self?.sharedNotice == notice { self?.sharedNotice=nil }
        }
    }
    func postSharedNotice(_ notice: SharedNotice) {
        guard sharedNotice != notice else { return }
        sharedNotice=notice
        showToast?(sharedNoticeToast(notice))
    }
    /// Called when 布局模式 changes. Switching to shared mode seeds the shared layout once; per-monitor files are never changed.
    func layoutModeChanged() {
        MonitorRecognition.layoutMode=layoutMode
        sharedNotice=nil; pendingSpacesNeeded=nil
        guard !RenderMode.snapshot else { return }
        if layoutMode == .sharedExternal {
            let physical=MonitorRecognition.physicalExternalMonitors()
            if let library=screenLibrary,let source=try? SharedLayout.seed(library:library,preferredKey:physical.count==1 ? physical[0].identity.key : nil) {
                let name=savedScreens.first{ $0.key==source }?.name ?? "外接屏"
                showToast?(Toast(icon:"square.on.square",tone:.success,title:"已切换为共用一套",detail:"用「\(name)」现在的布局作为共用布局，原来各屏的记录都保留着。",duration:6))
            }
            if !SeparateSpaces.enabled { postSharedNotice(SharedNotice(kind:.separateSpacesOff)) }
            else if physical.count>1 { postSharedNotice(SharedNotice(kind:.multipleMonitors)) }
        }
        selectedScreenKey=nil; previewVersion=nil; previewRecord=nil
        refreshExternalMonitor()
    }
    /// After a shared-mode restore: remember how many Spaces are needed so adding them triggers another restore.
    func noteSharedPlan(_ plan: QuickRestorePlan) {
        guard sharedModeActive else { return }
        if plan.missingDesktops>0 {
            pendingSpacesNeeded=plan.desktopsNeeded
            postSharedNotice(SharedNotice(kind:.missingSpaces(plan.missingDesktops)))
        } else {
            pendingSpacesNeeded=nil
            if case .missingSpaces? = sharedNotice?.kind { sharedNotice=nil }
        }
    }
}

/// Shared mode only. Every few seconds records the ordinary Spaces per display (read only, no AX) so that
/// (1) an unplug can be compared with the state just before it, and (2) Spaces added after a "too few Spaces"
/// notice trigger another restore. Never creates, deletes or reorders Spaces.
final class SharedSpaceWatcher {
    private weak var model: Model?
    private var timer: Timer?
    private(set) var last: SpaceCensus?
    private var lastPhysicalCount = -1
    static let interval: TimeInterval=4
    func start(model: Model) {
        self.model=model
        let t=Timer(timeInterval:Self.interval,repeats:true) { [weak self] _ in self?.tick() }
        timer=t; RunLoop.main.add(t,forMode:.common)
        tick()
    }
    private func census() -> SpaceCensus? {
        guard let model else { return nil }
        let displays=MacEnvironment.displays()
        guard let spaces=try? model.spaces.spaces(displays:displays) else { return nil }
        return SpaceCensus.take(displays,spaces,externalCount:displays.filter{ $0.role == .external }.count)
    }
    func screensChanged() {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.tick() }
    }
    private func tick() {
        guard let model,model.layoutMode == .sharedExternal,!RenderMode.snapshot else { last=nil; lastPhysicalCount = -1; return }
        let physical=MonitorRecognition.physicalExternalMonitors().count
        if physical != lastPhysicalCount {
            if physical>1 && lastPhysicalCount>=0 { model.postSharedNotice(SharedNotice(kind:.multipleMonitors)) }
            else if case .multipleMonitors? = model.sharedNotice?.kind { model.sharedNotice=nil }
            lastPhysicalCount=physical
        }
        guard let now=census() else { return }
        let previous=last
        last=now
        guard let previous else { return }
        if previous.externalCount>0 && now.externalCount==0 {
            model.pendingSpacesNeeded=nil
            // macOS moves the Spaces over a moment after the screen goes away; compare once things settle.
            DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
                guard let self,let model=self.model,model.layoutMode == .sharedExternal,let after=self.census(),after.externalCount==0 else { return }
                self.last=after
                let moved=SpaceCensus.migratedToBuiltIn(before:previous,after:after)
                if moved>0 { model.postSharedNotice(SharedNotice(kind:.migrated(moved))) }
            }
            return
        }
        if now.externalCount==1,previous.externalCount==1,now.external.count>previous.external.count,
           let needed=model.pendingSpacesNeeded,model.sharedModeActive,!model.busy,!model.showingQuickRestore {
            if let until=model.pausedUntil,Date()<until { return }
            _=needed   // the user added Spaces after our notice: restore again (only unambiguous windows, undoable)
            let outcome=model.directRestore(.automatic)
            if let toast=model.restoreToast(outcome,trigger:.automatic) { model.showToast?(toast) }
        }
    }
}
