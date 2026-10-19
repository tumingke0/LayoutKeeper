// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

/// Reconnect / wake handling. Stage 1: screens stable for 3 s (ReconnectWatch). Then the per-monitor policy decides:
/// ask once → remember the answer; ask → prompt; auto → stage 2 waits until window frames stop moving (FrameSettle),
/// then restores only unambiguous windows and posts an undoable notification. Unplugging does nothing. Pause suppresses all.
final class ReconnectCoordinator {
    let model: Model
    let showMain: () -> Void
    private var session: AttachSession
    private var timer: Timer?
    private var settleTimer: Timer?
    private var panel: NSPanel?
    /// True while finishAuto runs directRestore. Its retry pumps the run loop, so display events and timers can fire
    /// inside it; evaluate must not start the same session a second time meanwhile.
    private var attemptInFlight=false
    /// An attach is pending or running: the live recorder must not record (windows are about to move or migrating).
    var attachActive: Bool { session.isPending || session.open != nil || attemptInFlight }
    init(model: Model,showMain: @escaping () -> Void) {
        self.model=model; self.showMain=showMain
        session=AttachSession(initialMonitorKey:model.currentExternalMonitor.map(Self.physicalKey),settleInterval:3)
    }
    /// Layout key + this display's runtime UUID. Two different monitors can share one layout key (shared-external),
    /// so the key alone would make "unplug A, plug B within 3 s" look like a blip on the same monitor.
    static func physicalKey(_ m: ConnectedMonitor) -> String { "\(m.identity.key)@\(RestoreLog.d(m.runtimeDisplayToken))" }
    static func screenFingerprint() -> String {
        NSScreen.screens.map { screen in
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let f=screen.frame
            return "\(id):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
        }.sorted().joined(separator:"|")
    }
    private var eventCount=0
    private var eventStarted: Date?
    func note(_ event: ReconnectWatch.Event) {
        eventCount+=1
        // LayoutKeeper's own display arrangement switch: same displays, only their origins moved. Not a plug-in,
        // a wake or an unplug, so the attach session is not touched (AttachSession would also classify it as
        // "same monitor, no wake"; this makes it explicit). A real plug/unplug changes the display set and is never covered.
        if event == .screens,model.ownArrangementChange() {
            model.logRestore("event \(event) #\(eventCount): LayoutKeeper's own display arrangement change (\(model.arrangementPreview != nil ? "awaiting keep/revert" : model.arrangementGuard.inProgress ? "in progress" : "just finished")); not a plug-in, attach session untouched, no restore")
            return
        }
        let fp=Self.screenFingerprint()
        model.refreshExternalMonitor()
        let keyNow=model.currentExternalMonitor.map(Self.physicalKey)
        if !session.isPending && settleTimer == nil { eventStarted=Date(); model.logSession("display event \(event) (#\(eventCount))") }
        model.logRestore("event \(event) #\(eventCount) fingerprint=\(RestoreLog.hash(fp)) screens=\(NSScreen.screens.count) monitorNow=\(RestoreLog.key(keyNow)) pendingAlready=\(session.isPending) sinceFirst=\(eventStarted.map{ String(format:"%.2fs",Date().timeIntervalSince($0)) } ?? "-") lastSettled=\(RestoreLog.key(session.lastSettledKey)) openSession=\(session.open.map{ "#\($0.id)" } ?? "-")")
        if let t=settleTimer,t.isValid { model.logRestore("cancel: window-settle wait interrupted by a new display event; attach #\(session.open?.id ?? 0) goes back to waiting (not dropped)") }
        settleTimer?.invalidate(); settleTimer=nil
        // Busy timeout is per attempt: a display event restarts the attempt, so its busy clock starts over (AttachSession.note).
        session.note(wake:event == .wake,at:Date(),fingerprint:fp,monitorKeyNow:keyNow)
        schedule(after:session.settleInterval+0.2)
    }
    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let t=Timer(timeInterval:max(delay,0.2),repeats:false) { [weak self] _ in self?.evaluate() }
        timer=t; RunLoop.main.add(t,forMode:.common)
    }
    /// Back to waiting: the same session starts again after `delay`.
    private func requeue(_ why: String,delay: TimeInterval) {
        model.logRestore("attach #\(session.open?.id ?? 0): back to waiting — \(why)")
        session.requeue(at:Date(),delay:delay)
        schedule(after:delay+0.05)
    }
    private func close(_ id: Int,_ result: String) {
        if let line=session.finish(id:id,result:result) { model.logRestore(line); model.logSession(line) }
        model.arrivalSessionClosed()
    }
    private func evaluate() {
        if attemptInFlight { model.logRestore("reconnect: restore in progress, evaluating again in 1s"); schedule(after:1); return }
        model.refreshExternalMonitor()
        let monitor=model.currentExternalMonitor
        var decision=session.evaluate(at:Date(),fingerprint:Self.screenFingerprint(),monitorKey:monitor.map(Self.physicalKey))
        if case .closed(_,let line)=decision { model.logRestore(line); model.logSession(line); decision=session.startOpened() }
        switch decision {
        case .wait(let until): model.logRestore(String(format:"reconnect: screens still changing, wait %.2fs more",until.timeIntervalSinceNow)); schedule(after:until.timeIntervalSinceNow+0.1)
        case .idle, .closed: break
        case .ignored(let note):
            model.logRestore("reconnect: \(note)")
        case .start(let id,let key,let retry):
            model.logRestore("attach #\(id) start\(retry ? " (retry)" : ""): screens settled after \(eventStarted.map{ String(format:"%.2fs",Date().timeIntervalSince($0)) } ?? "?"), monitor=\(RestoreLog.key(key))")
            model.logRestoreLines(model.environmentLines(label:"settled"))
            guard let monitor,Self.physicalKey(monitor)==key else { requeue("monitor not readable at start",delay:1); return }
            model.activateArrival(for:monitor,session:id)
            trigger(monitor,id:id)
        }
    }
    private func trigger(_ monitor: ConnectedMonitor,id: Int) {
        if model.busy || model.showingQuickRestore {
            if session.noteBusy(at:Date()) { close(id,"skipped reason=busy-for-\(Int(AttachSession.busyTimeout))s (\(model.busyText))"); return }
            requeue("another task is running (\(model.busyText)), retry in 1s",delay:1); return
        }
        session.notBusy()
        model.refreshAuthorization(); guard model.trusted else { close(id,"skipped reason=no-accessibility-permission"); return }
        guard model.externalRecord != nil || model.activeArrival(for:monitor.identity,saved:nil) != nil else { close(id,"skipped reason=no-saved-layout-or-live-record-for-\(RestoreLog.key(monitor.identity.key))"); return }
        let name=model.monitorPreferences.displayName(monitor.identity)
        let action=ReconnectPolicy.action(global:model.autoRestoreMode,perMonitor:model.monitorPreferences.restore(monitor.identity.key),pausedUntil:model.pausedUntil,now:Date())
        model.logRestore("attach #\(id): policy=\(action) (global=\(model.autoRestoreMode) perMonitor=\(model.monitorPreferences.restore(monitor.identity.key).map{"\($0)"} ?? "-") pausedUntil=\(model.pausedUntil.map{"\($0)"} ?? "-") choicePrompt=\(Self.choicePromptEnabled))")
        switch action {
        case .none: close(id,"skipped reason=policy-off")
        case .paused: close(id,"skipped reason=paused")
        case .auto: waitForWindowsThenRestore(monitor,id:id)
        case .ask where !Self.choicePromptEnabled, .askOnce where !Self.choicePromptEnabled:
            // 0.6.2: the choice panel is disabled. A closable notice with one button replaces it; nothing is remembered.
            close(id,"notice-shown reason=ask-mode (no automatic restore)")
            model.notify?(Self.reconnectNotice(name:name,restore:{ [weak self] in self?.model.quickRestore() }))
        case .ask: close(id,"prompt-shown reason=ask-mode"); askNow(monitor,name:name)
        case .askOnce:
            close(id,"prompt-shown reason=ask-once")
            present(Self.askOncePrompt(name:name,
                automatic:{ [weak self] in self?.remember(.automatic,monitor); self?.model.quickRestore() },
                askEachTime:{ [weak self] in self?.remember(.askEachTime,monitor); self?.askNow(monitor,name:name) },
                never:{ [weak self] in self?.remember(.never,monitor) }))
        }
    }
    /// The reconnect choice panel (「以后自动恢复？」/「恢复这块屏幕保存的窗口布局？」) was hard to understand, so 0.6.2
    /// turns it off. The code stays; set this to true to bring it back.
    static let choicePromptEnabled=false
    static func reconnectNotice(name: String,restore: @escaping () -> Void) -> UserNotice {
        UserNotice(title:lk("接上了「%@」", "\(name)"),detail:lk("布局和保存的不一样时，点「恢复布局」；只移动能唯一确认的窗口，可以撤销。想接上就自动恢复，可在菜单「接上屏幕时」选「自动恢复」。"),
              actions:[UserNotice.Action(.restoreNow,run:restore)],duration:15)
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
    /// Wake the saved apps, then read their window frames until they are unchanged for 1 s (max 6 s), read-only.
    /// Any interruption sends the session back to waiting; it is never dropped here.
    private func waitForWindowsThenRestore(_ monitor: ConnectedMonitor,id: Int) {
        settleTimer?.invalidate()
        guard let record=model.externalRecord else { close(id,"skipped reason=no-saved-layout"); return }
        let started=Date()
        model.warmUpSavedApps(record)
        model.windows.patientReads=true
        let read: Snapshot?
        do { read=try model.externalLayoutSnapshot() } catch { read=nil; model.logRestore("attach #\(id): window scan error \(String(describing:error).prefix(120))") }
        model.windows.patientReads=false
        model.logRestore(String(format:"attach #\(id): warm-up + first scan took %.2fs, scan issues=%d",Date().timeIntervalSince(started),model.windows.issues.count))
        guard let snapshot=read else { model.logRestore("attach #\(id): window scan failed, restoring anyway"); finishAuto(monitor,id:id); return }
        let bundles=Set(record.profile.windows.map(\.selector.bundleID))
        let tokens=snapshot.windows.filter{bundles.contains($0.selector.bundleID)}.map(\.token)
        var settle=FrameSettle(quiet:1.0,maxWait:6)
        func sample() -> [String:Rect] {
            var frames=[String:Rect]()
            for token in tokens { if let w=try? model.windows.readWindow(token:token) { frames[token]=w.frame } }
            return frames
        }
        let first=sample()
        model.logRestore("attach #\(id): waiting for windows to settle tracked=\(tokens.count) readable=\(first.count) apps=\(bundles.sorted()) quiet=1s max=6s")
        _=settle.observe(first,at:Date())
        let settleStart=Date()
        var samples=0, last=first
        let t=Timer(timeInterval:0.25,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.model.refreshExternalMonitor()
            guard self.model.currentExternalMonitor.map(Self.physicalKey) == Self.physicalKey(monitor) else { timer.invalidate(); self.settleTimer=nil; self.requeue("monitor changed while waiting for windows (now \(RestoreLog.key(self.model.currentExternalMonitor?.identity.key)))",delay:self.session.settleInterval); return }
            let now=sample(); samples+=1
            let moved=now.filter{ last[$0.key] != $0.value }.map(\.key)
            if !moved.isEmpty { self.model.logRestore(String(format:"attach #\(id): +%.2fs windows still moving: ",Date().timeIntervalSince(settleStart))+moved.prefix(8).map{ "\($0)\(RestoreLog.r(now[$0]))" }.joined(separator:" ")) }
            last=now
            let decision=settle.observe(now,at:Date())
            if decision != .waiting { timer.invalidate(); self.settleTimer=nil; self.model.logRestore(String(format:"attach #\(id): windows %@ after %.2fs (%d samples)",decision == .settled ? "settled" : "still moving after 6 s",Date().timeIntervalSince(settleStart),samples)); self.finishAuto(monitor,id:id) }
        }
        settleTimer=t; RunLoop.main.add(t,forMode:.common)
    }
    static let followUpTimeout: TimeInterval = 30
    private var followUpTimer: Timer?
    private func resultLine(_ o: DirectRestoreOutcome,notice: UserNotice?,extra: String = "") -> String {
        "\(o.error == nil ? "ran" : "error") restored=\(o.restored) attempted=\(o.attempted) notConfident=\(o.skippedAuto) needsConfirmation=\(o.needsConfirmation) failures=\(o.failures.map{ "\($0.bundleID):\($0.reason.rawValue)" }) error=\(o.error.map{ String($0.prefix(60)) } ?? "-")\(extra) notice=\(notice == nil ? "none" : "posted")"
    }
    /// Step 1 restores what fits now. If it had to auto-add desktops, the session stays open (in flight) until the
    /// add finishes; step 2 restores again in the same session and one result line covers both.
    private func finishAuto(_ monitor: ConnectedMonitor,id: Int) {
        // The preview panel shares quickPlan with directRestore: treat it as busy, like trigger does.
        if model.busy || model.showingQuickRestore {
            if session.noteBusy(at:Date()) { close(id,"skipped reason=busy-for-\(Int(AttachSession.busyTimeout))s (\(model.busyText))"); return }
            requeue("busy at restore time (\(model.busyText)), retry in 1s",delay:1); return
        }
        model.refreshExternalMonitor()
        guard model.currentExternalMonitor.map(Self.physicalKey) == Self.physicalKey(monitor) else { requeue("screen changed before restore (now \(RestoreLog.key(model.currentExternalMonitor?.identity.key)))",delay:session.settleInterval); return }
        if let until=model.pausedUntil,Date()<until { close(id,"skipped reason=paused-until-\(until)"); return }
        model.logRestore("attach #\(id): step 1 restore (same code as manual, confident windows only)")
        attemptInFlight=true
        model.autoSpacesStartedByRestore=false; earlyFollowUp=nil
        model.autoSpacesFollowUp={ [weak self] result in self?.autoSpacesDone(result,monitor:monitor,id:id) }
        var outcome=model.directRestore(.automatic)
        // A slow app (often right after wake) can still miss the first run: try once more a little later.
        if outcome.failures.contains(where:{ $0.reason == .notResponding }) {
            model.logRestore("attach #\(id): retrying once for apps that did not respond")
            RunLoop.current.run(until:Date(timeIntervalSinceNow:2))
            model.refreshExternalMonitor()
            if !model.busy,model.currentExternalMonitor.map(Self.physicalKey) == Self.physicalKey(monitor) {
                outcome=Self.merge(outcome,model.directRestore(.automatic))
            }
        }
        model.autoSpacesFollowUp=nil
        if model.autoSpacesStartedByRestore,session.beginFollowUp(id:id) {
            model.logRestore("attach #\(id): step 1 done (restored=\(outcome.restored)); waiting for auto-add desktops (max \(Int(Self.followUpTimeout))s)")
            step1=outcome
            if let early=earlyFollowUp { earlyFollowUp=nil; autoSpacesDone(early,monitor:monitor,id:id); return }
            followUpTimer?.invalidate()
            let t=Timer(timeInterval:Self.followUpTimeout,repeats:false) { [weak self] _ in
                guard let self,self.session.followUpArrived(id:id) else { return }
                let notice=self.model.restoreNotice(outcome,trigger:.automatic)
                self.endInFlight(); self.close(id,self.resultLine(outcome,notice:notice,extra:" autoSpaces=timeout"))
                if let notice { self.model.notify?(notice) }
            }
            followUpTimer=t; RunLoop.main.add(t,forMode:.common)
            return
        }
        let notice=model.restoreNotice(outcome,trigger:.automatic)
        endInFlight(); close(id,resultLine(outcome,notice:notice))
        if let notice { model.notify?(notice) }
    }
    private var step1=DirectRestoreOutcome()
    private func endInFlight() { attemptInFlight=false; followUpTimer?.invalidate(); followUpTimer=nil }
    /// An add that finishes while step 1 is still running (its slow-app retry pumps the run loop) is held here and
    /// handled as soon as step 1 hands over, instead of being lost.
    private var earlyFollowUp: Result<Int,AutoSpacesFailure>?
    private func autoSpacesDone(_ result: Result<Int,AutoSpacesFailure>,monitor: ConnectedMonitor,id: Int) {
        if attemptInFlight,session.open?.id == id,!session.awaitingFollowUp { model.logRestore("attach #\(id): auto-add finished during step 1; handled after it"); earlyFollowUp=result; return }
        guard session.followUpArrived(id:id) else { model.logRestore("attach #\(id): late auto-add result ignored (session already ended)"); return }
        followUpTimer?.invalidate(); followUpTimer=nil
        var outcome=step1, extra: String
        switch result {
        case .success(let n):
            model.refreshExternalMonitor()
            if model.currentExternalMonitor.map(Self.physicalKey) == Self.physicalKey(monitor),!model.busy {
                model.logRestore("attach #\(id): step 2 restore after adding \(n) desktop(s)")
                outcome=Self.merge(step1,model.directRestore(.automatic)); extra=" autoSpaces=added\(n)"
            } else { extra=" autoSpaces=added\(n) step2=skipped(screen changed or busy)" }
        case .failure(let e): extra=" autoSpaces=failed(\(e.description.prefix(40)))"
        }
        let notice=model.restoreNotice(outcome,trigger:.automatic)
        endInFlight(); close(id,resultLine(outcome,notice:notice,extra:extra))
        if let notice { model.notify?(notice) }
    }
    /// Step totals per window (RestoreTally: the latest step decides each window); what is still left (not confident, needs confirmation, failures, error)
    /// comes from the latest step, which saw the newest state.
    static func merge(_ a: DirectRestoreOutcome,_ b: DirectRestoreOutcome) -> DirectRestoreOutcome {
        var o=b; o.tally=a.tally; o.tally.add(b.tally); o.restored=o.tally.restored; o.attempted=o.tally.attempted; return o
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
