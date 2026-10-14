// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

/// Reconnect / wake handling. Stage 1: screens stable for 3 s (ReconnectWatch). Then the per-monitor policy decides:
/// ask once → remember the answer; ask → prompt; auto → stage 2 waits until window frames stop moving (FrameSettle),
/// then restores only unambiguous windows and shows an undoable toast. Unplugging does nothing. Pause suppresses all.
final class ReconnectCoordinator {
    let model: Model
    let showMain: () -> Void
    private var watch: ReconnectWatch
    private var timer: Timer?
    private var settleTimer: Timer?
    private var panel: NSPanel?
    init(model: Model,showMain: @escaping () -> Void) {
        self.model=model; self.showMain=showMain
        watch=ReconnectWatch(initialMonitorKey:model.currentExternalMonitor?.identity.key,settleInterval:3)
    }
    static func screenFingerprint() -> String {
        NSScreen.screens.map { screen in
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let f=screen.frame
            return "\(id):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
        }.sorted().joined(separator:"|")
    }
    func note(_ event: ReconnectWatch.Event) {
        settleTimer?.invalidate()
        watch.note(event,at:Date(),fingerprint:Self.screenFingerprint())
        schedule(after:watch.settleInterval+0.2)
    }
    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let t=Timer(timeInterval:max(delay,0.2),repeats:false) { [weak self] _ in self?.evaluate() }
        timer=t; RunLoop.main.add(t,forMode:.common)
    }
    private func evaluate() {
        model.refreshExternalMonitor()
        let monitor=model.currentExternalMonitor
        let hasLayout=model.externalRecord != nil
        // The global mode is only one input to the policy (a remembered per-monitor choice overrides it), so the
        // debounce itself always runs and the policy below decides.
        let decision=watch.evaluate(at:Date(),fingerprint:Self.screenFingerprint(),monitorKey:monitor?.identity.key,hasLayout:hasLayout,mode:.ask)
        switch decision {
        case .wait(let until): schedule(after:until.timeIntervalSinceNow+0.1)
        case .trigger(let key): if let monitor,monitor.identity.key==key { trigger(monitor) }
        case .idle, .settled: break
        }
    }
    private func trigger(_ monitor: ConnectedMonitor) {
        guard !model.busy,!model.showingQuickRestore else { return }
        model.refreshAuthorization(); guard model.trusted else { return }
        let name=model.monitorPreferences.displayName(monitor.identity)
        let action=ReconnectPolicy.action(global:model.autoRestoreMode,perMonitor:model.monitorPreferences.restore(monitor.identity.key),pausedUntil:model.pausedUntil,now:Date())
        switch action {
        case .none, .paused: return
        case .auto: waitForWindowsThenRestore(monitor)
        case .ask where !Self.choicePromptEnabled, .askOnce where !Self.choicePromptEnabled:
            // 0.6.2: the choice panel is disabled. A closable notice with one button replaces it; nothing is remembered.
            model.showToast?(Self.reconnectNotice(name:name,restore:{ [weak self] in self?.model.quickRestore() }))
        case .ask: askNow(monitor,name:name)
        case .askOnce:
            present(Self.askOncePrompt(name:name,
                automatic:{ [weak self] in self?.remember(.automatic,monitor); self?.waitForWindowsThenRestore(monitor) },
                askEachTime:{ [weak self] in self?.remember(.askEachTime,monitor); self?.askNow(monitor,name:name) },
                never:{ [weak self] in self?.remember(.never,monitor) }))
        }
    }
    /// The reconnect choice panel (「以后自动恢复？」/「恢复这块屏幕保存的窗口布局？」) was hard to understand, so 0.6.2
    /// turns it off. The code stays; set this to true to bring it back.
    static let choicePromptEnabled=false
    static func reconnectNotice(name: String,restore: @escaping () -> Void) -> Toast {
        Toast(icon:"display.2",tone:.info,title:lk("接上了「%@」", "\(name)"),detail:lk("布局和保存的不一样时，点「恢复布局」；只移动能唯一确认的窗口，可以撤销。想接上就自动恢复，可在菜单「接上屏幕时」选「自动恢复」。"),
              actions:[Toast.Action(title:lk("恢复布局"),run:restore)],duration:15)
    }
    static func askOncePrompt(name: String,automatic: @escaping () -> Void,askEachTime: @escaping () -> Void,never: @escaping () -> Void) -> ReconnectPrompt {
        ReconnectPrompt(icon:"sparkles.rectangle.stack",title:lk("以后接上「%@」时自动恢复布局？", "\(name)"),
            message:lk("只移动能唯一确认的窗口，完成后可以撤销。随时可在菜单「接上屏幕时」修改。"),
            actions:[PromptAction(title:lk("自动恢复"),style:.primary,run:automatic),PromptAction(title:lk("每次先问"),style:.normal,run:askEachTime),PromptAction(title:lk("不要"),style:.cancel,run:never)])
    }
    static func askPrompt(name: String,restore: @escaping () -> Void,preview: @escaping () -> Void) -> ReconnectPrompt {
        ReconnectPrompt(icon:"display.2",title:lk("检测到「%@」", "\(name)"),message:lk("恢复这块屏幕保存的窗口布局？只移动能唯一确认的窗口，可以撤销。"),
            actions:[PromptAction(title:lk("恢复布局"),style:.primary,run:restore),PromptAction(title:lk("这次不用"),style:.cancel) {},PromptAction(title:lk("先预览…"),style:.link,run:preview)])
    }
    private func remember(_ answer: AskOnceAnswer,_ monitor: ConnectedMonitor) {
        model.monitorPreferences.setRestore(answer.mode,for:monitor.identity.key,seenName:monitor.identity.name)
    }
    private func askNow(_ monitor: ConnectedMonitor,name: String) {
        present(Self.askPrompt(name:name,restore:{ [weak self] in self?.model.quickRestore() },preview:{ [weak self] in self?.model.openPreviewPanel?(true) }))
    }
    /// Stage 2: read the saved apps' window frames until they are unchanged for ~1 s (max ~5 s), read-only.
    private func waitForWindowsThenRestore(_ monitor: ConnectedMonitor) {
        settleTimer?.invalidate()
        guard let record=model.externalRecord,let snapshot=try? model.externalLayoutSnapshot() else { finishAuto(monitor); return }
        let bundles=Set(record.profile.windows.map(\.selector.bundleID))
        let tokens=snapshot.windows.filter{bundles.contains($0.selector.bundleID)}.map(\.token)
        var settle=FrameSettle()
        func sample() -> [String:Rect] {
            var frames=[String:Rect]()
            for token in tokens { if let w=try? model.windows.readWindow(token:token) { frames[token]=w.frame } }
            return frames
        }
        _=settle.observe(sample(),at:Date())
        let t=Timer(timeInterval:0.25,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.model.currentExternalMonitor?.identity.key == monitor.identity.key else { timer.invalidate(); return }
            if settle.observe(sample(),at:Date()) != .waiting { timer.invalidate(); self.finishAuto(monitor) }
        }
        settleTimer=t; RunLoop.main.add(t,forMode:.common)
    }
    private func finishAuto(_ monitor: ConnectedMonitor) {
        guard !model.busy,model.currentExternalMonitor?.identity.key == monitor.identity.key else { return }
        if let until=model.pausedUntil,Date()<until { return }
        let outcome=model.directRestore(.automatic)
        if let toast=model.restoreToast(outcome,trigger:.automatic) { model.showToast?(toast) }
    }
    private func present(_ prompt: ReconnectPrompt) {
        panel?.close()
        let p=NSPanel(contentRect:NSRect(x:0,y:0,width:400,height:150),styleMask:[.titled,.closable,.nonactivatingPanel,.fullSizeContentView],backing:.buffered,defer:false)
        p.title="LayoutKeeper"; p.titleVisibility = .hidden; p.titlebarAppearsTransparent=true; p.isMovableByWindowBackground=true; p.isFloatingPanel=true; p.level = .floating; p.hidesOnDeactivate=false; p.isReleasedWhenClosed=false
        p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        let close={ [weak p] in p?.close() }
        var wrapped=prompt
        wrapped.actions=prompt.actions.map{ a in PromptAction(title:a.title,style:a.style) { close(); a.run() } }
        let hosting=NSHostingView(rootView:ReconnectPanelView(prompt:wrapped))
        p.contentView=hosting; p.setContentSize(hosting.fittingSize)
        if let screen=NSScreen.main {
            let v=screen.visibleFrame; p.setFrameOrigin(NSPoint(x:v.maxX-p.frame.width-16,y:v.maxY-p.frame.height-16))
        }
        p.orderFrontRegardless(); panel=p
    }
}

struct PromptAction {
    enum Style { case primary, normal, cancel, link }
    var title: String
    var style: Style
    var run: () -> Void
}
struct ReconnectPrompt {
    var icon: String
    var title: String
    var message: String
    var actions: [PromptAction]
}

struct ReconnectPanelView: View {
    let prompt: ReconnectPrompt
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:prompt.icon).font(.system(size:20,weight:.medium)).foregroundStyle(.white)
                    .frame(width:42,height:42)
                    .background(RoundedRectangle(cornerRadius:10,style:.continuous).fill(LinearGradient(colors:[Color.accentColor,Color.accentColor.opacity(0.7)],startPoint:.top,endPoint:.bottom)))
                VStack(alignment:.leading,spacing:3) {
                    Text(prompt.title).font(.headline).fixedSize(horizontal:false,vertical:true)
                    Text(prompt.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:0)
            }
            HStack {
                ForEach(Array(prompt.actions.enumerated()).filter{$0.element.style == .link},id:\.offset) { _,a in Button(a.title,action:a.run).buttonStyle(.link) }
                Spacer()
                ForEach(Array(prompt.actions.enumerated()).filter{$0.element.style == .cancel || $0.element.style == .normal},id:\.offset) { _,a in
                    if a.style == .cancel { Button(a.title,action:a.run).keyboardShortcut(.cancelAction) } else { Button(a.title,action:a.run) }
                }
                ForEach(Array(prompt.actions.enumerated()).filter{$0.element.style == .primary},id:\.offset) { _,a in Button(a.title,action:a.run).primaryButton().keyboardShortcut(.defaultAction) }
            }.controlSize(.regular)
        }
        .padding(.horizontal,16).padding(.top,RenderMode.snapshot ? 16 : 26).padding(.bottom,14).frame(width:400)
        .windowBackdrop()
    }
}
