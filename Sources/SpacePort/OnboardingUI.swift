// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ServiceManagement
import SwiftUI
import LayoutCore
import MacAdapters

/// Open at login via SMAppService.mainApp (macOS 13+). Errors are reported, never thrown at the user.
enum LoginItem {
    static var status: LaunchAtLoginStatus {
        if RenderMode.snapshot { return .enabled }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable("系统找不到这个应用（请从 .app 启动）")
        @unknown default: return .disabled
        }
    }
    @discardableResult static func set(_ on: Bool) -> LaunchAtLoginStatus {
        guard !RenderMode.snapshot else { return on ? .enabled : .disabled }
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch {
            let s=status
            return s == .requiresApproval ? s : .unavailable(error.localizedDescription)
        }
        return status
    }
    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

final class OnboardingController: ObservableObject {
    @Published var flow: OnboardingFlow
    @Published var justGranted=false
    @Published var launchAtLogin=true
    @Published var loginStatus: LaunchAtLoginStatus?
    @Published var permissionNote=""
    @Published var saveNote: (text: String,ok: Bool)?
    @Published var reminderSet=false
    let model: Model
    var onFinish: (OnboardingFlow) -> Void={ _ in }
    private var timer: Timer?
    init(model: Model,reason: OnboardingReason) {
        self.model=model
        if !RenderMode.snapshot { model.refreshAuthorization() }
        flow=OnboardingFlow(reason:reason,trusted:model.trusted)
        if RenderMode.snapshot { return }
        let current=LoginItem.status
        if current.isOn { launchAtLogin=true; loginStatus=current }
    }
    /// Polls AXIsProcessTrusted about once a second while the permission step is visible.
    func startPolling() {
        timer?.invalidate()
        let t=Timer(timeInterval:1,repeats:true) { [weak self] _ in self?.poll() }
        timer=t; RunLoop.main.add(t,forMode:.common)
    }
    func stopPolling() { timer?.invalidate(); timer=nil }
    private func poll() {
        guard flow.step == .permission,!flow.finished else { return }
        model.refreshAuthorization()
        if flow.observePermission(model.trusted) {
            justGranted=true
            DispatchQueue.main.asyncAfter(deadline:.now()+1.0) { [weak self] in
                guard let self,self.flow.step == .permission else { return }
                self.justGranted=false; self.next()
            }
        }
    }
    /// Explicit click only: show the system prompt, then open the Accessibility pane.
    func requestPermission() {
        ControlSettings.requestAccessibility()
        let opened=ControlSettings.openAccessibility(using:{ NSWorkspace.shared.open($0) })
        let pane=ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "设备控制和数据访问" : "辅助功能"
        permissionNote=opened ? "在“隐私与安全性 → \(pane)”里打开 LayoutKeeper 的开关，这里会自动继续。" : "系统设置未能打开，请手动前往“隐私与安全性 → \(pane)”。"
    }
    func next() {
        if flow.step == .launchAtLogin { loginStatus=LoginItem.set(launchAtLogin) }
        flow.advance()
        if flow.finished { finish() }
    }
    func back() { flow.back() }
    func skip() { flow.skip(); finish() }
    private func finish() { stopPolling(); onFinish(flow) }
    func saveNow() {
        switch model.saveExternalLayout() {
        case .saved(let count,_): saveNote=("已保存 \(count) 个窗口。以后用菜单栏或 ⌃⌥⌘R 恢复。",true)
        case .failed(let why): saveNote=(why,false)
        case .cancelled: break
        }
    }
    func remindLater() {
        Prefs.store?.set(true,forKey:FirstLayoutReminder.key)
        reminderSet=true
    }
}

struct OnboardingView: View {
    @ObservedObject var controller: OnboardingController
    @ObservedObject var model: Model
    init(controller: OnboardingController) { self.controller=controller; model=controller.model }
    var flow: OnboardingFlow { controller.flow }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:10) {
                Image(systemName:"rectangle.3.group.fill").font(.system(size:20,weight:.semibold))
                    .foregroundStyle(LinearGradient(colors:[Color.accentColor,Color.accentColor.opacity(0.6)],startPoint:.topLeading,endPoint:.bottomTrailing))
                Text(flow.reason == .missingPermission ? "LayoutKeeper 需要权限" : "欢迎使用 LayoutKeeper").font(.system(size:20,weight:.semibold,design:.rounded))
                Spacer()
                if flow.steps.count>1 { progress }
            }
            content.frame(maxWidth:.infinity,minHeight:200,alignment:.topLeading).padding(20).card()
            HStack {
                if flow.canGoBack { Button("上一步") { controller.back() } }
                Button(flow.reason == .missingPermission ? "以后再说" : "跳过引导") { controller.skip() }.buttonStyle(.link)
                Spacer()
                Text(flow.stepLabel).font(.caption).foregroundStyle(.secondary)
                if flow.step == .permission && !flow.permissionGranted {
                    Button(flow.primaryTitle) { controller.next() }.buttonStyle(.bordered)
                } else {
                    Button(flow.primaryTitle) { controller.next() }.primaryButton().keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large)
        }
        .padding(.horizontal,24).padding(.top,RenderMode.snapshot ? 22 : 34).padding(.bottom,20)
        .frame(width:540)
        .windowBackdrop()
    }
    private var progress: some View {
        HStack(spacing:6) {
            ForEach(Array(flow.steps.enumerated()),id:\.offset) { i,step in
                Capsule().fill(i <= flow.index ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width:i == flow.index ? 22 : 8,height:8)
                    .help(step.title)
            }
        }
    }
    @ViewBuilder private var content: some View {
        switch flow.step {
        case .permission: permission
        case .launchAtLogin: login
        case .firstLayout: firstLayout
        }
    }
    private func header(_ icon: String,_ title: String,_ text: String) -> some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:icon).font(.system(size:22)).foregroundStyle(Color.accentColor)
                .frame(width:46,height:46).background(Circle().fill(Color.accentColor.opacity(0.12)))
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.title3.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private var permission: some View {
        VStack(alignment:.leading,spacing:16) {
            header("hand.raised.fill","允许 LayoutKeeper 读取和移动窗口",
                   "macOS 的“辅助功能”权限用于读取窗口的位置、大小和标题，并把窗口放回原处。LayoutKeeper 只在本机工作，不联网，不读取窗口内容。")
            if flow.permissionGranted {
                Label(controller.justGranted ? "已获得权限，继续下一步…" : "已获得权限",systemImage:"checkmark.circle.fill")
                    .font(.body.weight(.medium)).foregroundStyle(Tone.success.color)
            } else {
                HStack(spacing:12) {
                    Button { controller.requestPermission() } label: { Label("打开系统设置",systemImage:"gearshape") }.primaryButton()
                    ProgressView().controlSize(.small)
                    Text("等待授权…").font(.callout).foregroundStyle(.secondary)
                }
                Text(controller.permissionNote.isEmpty ? "点按钮后，系统会弹出提示并打开“隐私与安全性”。打开 LayoutKeeper 的开关后，这里会自动继续。" : controller.permissionNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("每次重新编译（ad-hoc 签名）后，系统可能需要你重新添加一次。").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
    private var login: some View {
        VStack(alignment:.leading,spacing:16) {
            header("power","登录时自动打开","LayoutKeeper 常驻菜单栏，接上外接屏时才能及时恢复布局。可以随时在“设置 → 通用”里关闭。")
            Toggle("登录 Mac 时打开 LayoutKeeper",isOn:$controller.launchAtLogin).toggleStyle(.switch)
            if let message=controller.loginStatus?.message {
                HStack {
                    Label(message,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(Tone.warning.color)
                    if controller.loginStatus == .requiresApproval { Button("打开登录项") { LoginItem.openLoginItemsSettings() }.controlSize(.small) }
                }
            }
        }
    }
    private var firstLayout: some View {
        VStack(alignment:.leading,spacing:16) {
            if let monitor=model.currentExternalMonitor {
                header("square.and.arrow.down","保存第一份布局",
                       "把「\(model.monitorPreferences.displayName(monitor.identity))」上各个桌面的窗口摆好，然后保存。以后接上这块屏幕，就能一键恢复（菜单栏或 ⌃⌥⌘R）。")
                if let note=controller.saveNote {
                    Label(note.text,systemImage:note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(note.ok ? Tone.success.color : Tone.warning.color).fixedSize(horizontal:false,vertical:true)
                }
                if controller.saveNote?.ok != true {
                    HStack(spacing:12) {
                        Button { controller.saveNow() } label: { Label("现在保存",systemImage:"square.and.arrow.down") }
                            .primaryButton().disabled(!model.trusted || model.busy)
                        if !model.trusted { Text("需要先获得权限").font(.caption).foregroundStyle(.secondary) }
                        else { Text("也可以以后用菜单栏或 ⌃⌥⌘S 保存").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } else {
                header("display","接上外接屏后保存","现在没有连接外接屏。LayoutKeeper 按屏幕记住布局，接上后摆好窗口，用菜单栏“保存当前布局”或 ⌃⌥⌘S 保存。")
                if controller.reminderSet {
                    Label("好的，下次接上没有保存过布局的外接屏时会提醒你",systemImage:"bell.badge").font(.callout).foregroundStyle(Tone.success.color)
                } else {
                    Button { controller.remindLater() } label: { Label("下次接上外接屏时提醒我",systemImage:"bell") }.primaryButton()
                }
            }
        }
    }
}
