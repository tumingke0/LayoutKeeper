// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

enum SettingsTab: String, CaseIterable { case general, diagnostics }

struct SettingsView: View {
    @ObservedObject var model: Model
    var body: some View {
        TabView(selection:$model.settingsTab) {
            GeneralSettings(model:model).tabItem { Label("通用",systemImage:"gearshape") }.tag(SettingsTab.general)
            DiagnosticsSettings(model:model).tabItem { Label("诊断",systemImage:"stethoscope") }.tag(SettingsTab.diagnostics)
        }
        .frame(width:660,height:620)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: Model
    @State private var loginStatus=LoginItem.status
    var version: String {
        let v=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "开发版本"
        let b=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "未打包"
        return "\(v) (\(b))"
    }
    var body: some View {
        Form {
            Section("接上屏幕时") {
                Picker("默认",selection:$model.autoRestoreMode) { ForEach(AutoRestoreMode.allCases,id:\.self) { Text($0.title).tag($0) } }
                Text(model.autoRestoreMode == .auto ? "屏幕稳定、窗口停止移动后自动恢复能唯一确认的窗口；需要确认或在另一块屏幕上的窗口不会动。右上角提示可撤销。"
                     : (model.autoRestoreMode == .ask ? "每块屏幕第一次接上时问一次「以后自动恢复？」，记住你的选择。" : "不会自动提示，需要时用菜单栏或快捷键恢复。"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.monitorPreferences.entries.keys.sorted(),id:\.self) { key in
                    if let entry=model.monitorPreferences.entries[key],entry.restore != nil || entry.displayName != nil {
                        HStack {
                            Text(entry.label + (entry.displayName != nil && entry.seenName != nil ? "（\(entry.seenName!)）" : "")).lineLimit(1)
                            Spacer()
                            Picker("",selection:Binding<String>(get:{ entry.restore?.rawValue ?? "default" },set:{ value in
                                model.monitorPreferences.setRestore(AutoRestoreMode(rawValue:value),for:key)
                            })) {
                                Text("跟随默认").tag("default")
                                ForEach(AutoRestoreMode.allCases,id:\.self) { Text($0.title).tag($0.rawValue) }
                            }.labelsHidden().fixedSize()
                        }
                    }
                }
                HStack {
                    if let until=model.pausedUntil,Date()<until {
                        Label("自动恢复已暂停至 \(RelativeTime.clock(until))",systemImage:"pause.circle").foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复自动") { model.pausedUntil=nil }
                    } else {
                        Text("暂停自动恢复")
                        Spacer()
                        ForEach(AutoRestorePause.allCases,id:\.self) { option in Button(option.title) { model.pausedUntil=option.until(from:Date()) } }
                    }
                }
            }
            Section("全局快捷键") {
                Toggle("启用全局快捷键",isOn:$model.hotkeySettings.enabled)
                ForEach(HotkeyAction.allCases,id:\.self) { action in HotkeyRow(model:model,action:action) }
                HStack {
                    Text("不需要额外权限；按 Esc 取消录制。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { model.hotkeySettings = .defaults }.controlSize(.small).disabled(model.hotkeySettings == .defaults)
                }
            }
            Section("启动") {
                Toggle("登录 Mac 时打开 LayoutKeeper",isOn:Binding(get:{ loginStatus.isOn },set:{ loginStatus=LoginItem.set($0) }))
                if let message=loginStatus.message {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(Tone.warning.color)
                        Spacer()
                        if loginStatus == .requiresApproval { Button("打开登录项") { LoginItem.openLoginItemsSettings() }.controlSize(.small) }
                    }
                }
                Button("重新打开使用引导…") { model.openOnboarding?() }
            }
            Section("跨桌面恢复") {
                LabeledContent("状态") {
                    Label(model.crossSpaceSupport.enabled ? (model.crossSpaceSupport.isUntested ? "可用 · 未自检" : "可用") : "不可用",
                          systemImage:model.crossSpaceSupport.enabled ? (model.crossSpaceSupport.isUntested ? "checkmark.seal" : "checkmark.seal.fill") : "xmark.seal")
                        .foregroundStyle(model.crossSpaceSupport.enabled ? (model.crossSpaceSupport.isUntested ? Color.orange : Color.green) : Color.secondary)
                }
                Text(model.crossSpaceSupport.detail).font(.caption).foregroundStyle(.secondary)
                if model.crossSpaceSupport.isUntested { Button("去运行一键自检") { model.settingsTab = .diagnostics } }
            }
            Section("权限") {
                LabeledContent("辅助功能") {
                    Label(model.trusted ? "已授权" : "未授权",systemImage:model.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.trusted ? Color.green : Color.orange)
                }
                if !model.trusted { Button("打开系统设置") { model.openControlSettings() } }
                Text("只在你点击引导里的“打开系统设置”时才会弹出系统授权提示；这里只打开设置，不弹提示。").font(.caption).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("版本",value:version)
                LabeledContent("系统",value:"macOS \(model.systemBuildText)")
                LabeledContent("安装位置",value:AppInstallation.role(bundleURL:Bundle.main.bundleURL))
                LabeledContent("数据文件夹",value:"~/Library/Application Support/LayoutKeeper")
                Text(AppMigration.statusText).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onAppear { loginStatus=LoginItem.status }
    }
}

struct DiagnosticsSettings: View {
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                SelfTestSection(model:model)
                GroupBox("可保存窗口检查（只读）") {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Button(model.checkingCapture ? "正在检查…" : "检查可保存窗口") { model.inspectExternalCapture() }
                                .disabled(model.currentExternalMonitor==nil || !model.trusted || model.restoring || model.checkingCapture)
                            Spacer()
                        }
                        if !model.captureInspectionMessage.isEmpty { Text(model.captureInspectionMessage).font(.caption).foregroundStyle(.secondary) }
                        if let report=model.captureInspection ?? model.externalRecord?.captureReport { CaptureStatsView(model:model,report:report) }
                        if !model.externalMessage.isEmpty { Text(model.externalMessage).font(.caption).foregroundStyle(.secondary) }
                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                }
                GroupBox("技术信息") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("\(model.accessState.title) · \(model.crossSpaceSupport.summary)").font(.caption)
                        HStack { Button("刷新") { model.refresh() }; Button("导出诊断…") { model.exportDiagnostic() } }
                        DisclosureGroup("技术数据") { Text(model.diagnostic).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.font(.caption)
                        DisclosureGroup("上次操作详情") {
                            ForEach(Array(model.externalRestoreResults.enumerated()),id:\.offset) { _,r in Text("\(r.outcome.rawValue) · \(r.detail)").font(.caption) }
                            Text(model.message).font(.caption).textSelection(.enabled)
                        }.font(.caption)
                        DisclosureGroup("内存后端验证（不操作窗口）") {
                            HStack { Button("检查正常模拟") { model.simulation(false) }; Button("检查假成功应失败") { model.simulation(true) } }
                            ForEach(Array(model.results.enumerated()),id:\.offset) { _,r in Text("[\(r.outcome.rawValue)] \(r.detail)").font(.caption) }
                        }.font(.caption)
                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.padding(20)
        }
    }
}


/// Click, then press the new combination. Global hotkeys are suspended while recording so the old one can't fire.
struct HotkeyRow: View {
    @ObservedObject var model: Model
    let action: HotkeyAction
    @State private var monitor: Any?
    @State private var problem: String?
    var recording: Bool { model.recordingHotkey == action }
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            HStack {
                Text(action.title)
                Spacer()
                Button(recording ? "按下新的快捷键…" : (model.hotkeySettings.keys[action]?.display ?? "未设置")) { recording ? stop() : start() }
                    .font(.system(.body,design:.rounded).weight(.medium)).frame(minWidth:110)
                    .disabled(!model.hotkeySettings.enabled)
                if model.hotkeySettings.keys[action] != nil {
                    Button { model.hotkeySettings.keys[action]=nil } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("清除").disabled(!model.hotkeySettings.enabled)
                }
            }
            if let message=problem ?? model.hotkeyStatus[action]?.message {
                Label(message,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(Tone.warning.color)
            }
        }
        .onDisappear { if recording { stop() } }
    }
    private func start() {
        problem=nil; model.recordingHotkey=action; model.suspendHotkeys?(true)
        monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            var mods=HotkeyModifiers()
            if event.modifierFlags.contains(.command) { mods.insert(.command) }
            if event.modifierFlags.contains(.option) { mods.insert(.option) }
            if event.modifierFlags.contains(.control) { mods.insert(.control) }
            if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
            let key=Hotkey(keyCode:UInt32(event.keyCode),modifiers:mods)
            if let why=HotkeyRegistrar.validate(key) { problem=why; return nil }
            stop(apply:false)
            model.hotkeySettings.keys[action]=key   // re-registers all and reports conflicts
            return nil
        }
    }
    private func stop(apply: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor=nil; model.recordingHotkey=nil
        if apply { model.suspendHotkeys?(false) }
    }
}
