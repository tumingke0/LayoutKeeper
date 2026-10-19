// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

enum SettingsTab: String, CaseIterable { case general, displays, diagnostics }

struct SettingsView: View {
    @ObservedObject var model: Model
    var body: some View {
        TabView(selection:$model.settingsTab) {
            GeneralSettings(model:model).tabItem { Label(lk("通用"),systemImage:"gearshape") }.tag(SettingsTab.general)
            DisplaySettings(control:model.displayControl,model:model).tabItem { Label(lk("显示器"),systemImage:"sun.max") }.tag(SettingsTab.displays)
            DiagnosticsSettings(model:model).tabItem { Label(lk("诊断"),systemImage:"stethoscope") }.tag(SettingsTab.diagnostics)
        }
        .frame(width:660,height:620)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: Model
    @State private var loginStatus=LoginItem.status
    var version: String {
        let v=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? lk("开发版本")
        let b=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? lk("未打包")
        return "\(v) (\(b))"
    }
    @State private var language=AppLanguage.current
    var body: some View {
        Form {
            Section(lk("语言")) {
                Picker(lk("语言"),selection:$language) {
                    Text(lk("跟随系统")).tag(AppLanguage.system)
                    Text(verbatim:"English").tag(AppLanguage.english)
                    Text(verbatim:"简体中文").tag(AppLanguage.chinese)
                }
                .onChange(of:language) { _,value in AppLanguage.current=value }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text(lk("重启 LayoutKeeper 后生效。")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(lk("立即重启")) { AppLanguage.relaunch() }.controlSize(.small)
                    }
                }
            }
            Section(lk("布局模式")) {
                Picker(lk("布局模式"),selection:$model.layoutMode) { ForEach(LayoutMode.allCases,id:\.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.radioGroup)
                Text(model.layoutMode == .perMonitor
                     ? lk("公司、家里的外接屏各记各的布局。")
                     : lk("不管接的是哪块外接屏，都用同一套桌面和窗口。窗口按所在的桌面和相对位置保存，分辨率不同也能对上；原来同一个桌面上的窗口放回同一个桌面，顺序不变，桌面不够时先自动补，补不上的那几组窗口不移动，并提示你还缺几个。只在接一块外接屏时生效，接两块以上时自动按每块屏单独记。原来各屏的记录都保留。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if model.layoutMode == .sharedExternal && !(RenderMode.snapshot ? model.snapshotSeparateSpacesOff == false : SeparateSpaces.enabled) {
                    Label(lk("「显示器具有单独的空间」已关闭，共用模式需要打开它（系统设置 → 桌面与程序坞 → 调度中心，注销后生效）。"),systemImage:"exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Tone.warning.color).fixedSize(horizontal:false,vertical:true)
                }
            }
            if model.layoutMode == .sharedExternal {
                Section(lk("桌面管理")) {
                    Toggle(lk("接上外接屏时自动补齐缺少的桌面"),isOn:$model.autoAddSpaces)
                    // 0.6.8: 「拔掉外接屏后自动删掉空桌面」 is hidden and forced off (AutoSpaces.removeAvailable).
                    Text(lk("通过调度中心自动完成，操作时会闪一下。有全屏 App 或任何一步不对时会停下，改为提示你手动处理。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Section(lk("接上屏幕时")) {
                Picker(lk("默认"),selection:$model.autoRestoreMode) { ForEach(AutoRestoreMode.allCases,id:\.self) { Text($0.title).tag($0) } }
                Text(model.autoRestoreMode == .auto ? lk("屏幕稳定、窗口停止移动后自动恢复能唯一确认的窗口；需要确认或在另一块屏幕上的窗口不会动。右上角提示可撤销。")
                     : (model.autoRestoreMode == .ask ? lk("接上屏幕时右上角提示一下，点「恢复布局」才会恢复；提示可以直接关掉。") : lk("不会自动提示，需要时用菜单栏或快捷键恢复。")))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.monitorPreferences.entries.keys.sorted(),id:\.self) { key in
                    if let entry=model.monitorPreferences.entries[key],entry.restore != nil || entry.displayName != nil {
                        HStack {
                            Text(entry.label + (entry.displayName != nil && entry.seenName != nil ? lk("（%@）", "\(entry.seenName!)") : "")).lineLimit(1)
                            Spacer()
                            Picker("",selection:Binding<String>(get:{ entry.restore?.rawValue ?? "default" },set:{ value in
                                model.monitorPreferences.setRestore(AutoRestoreMode(rawValue:value),for:key)
                            })) {
                                Text(lk("跟随默认")).tag("default")
                                ForEach(AutoRestoreMode.allCases,id:\.self) { Text($0.title).tag($0.rawValue) }
                            }.labelsHidden().fixedSize()
                        }
                    }
                }
            }
            Section(lk("通知")) {
                Text(lk("结果和提示用 macOS 通知显示：点一下打开 LayoutKeeper，向右划掉即可关闭。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Text(model.notificationPermission.statusText).font(.caption)
                        .foregroundStyle(model.notificationPermission.blocksBanners ? Tone.warning.color : Color.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    if model.notificationPermission == .denied || model.notificationPermission == .alertsOff {
                        Button(lk("打开通知设置")) { NotificationSettings.open() }.controlSize(.small)
                    }
                }
            }
            Section(lk("全局快捷键")) {
                Toggle(lk("启用全局快捷键"),isOn:$model.hotkeySettings.enabled)
                ForEach(HotkeyAction.allCases,id:\.self) { action in HotkeyRow(model:model,action:action) }
                HStack {
                    Text(lk("不需要额外权限；按 Esc 取消录制。")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(lk("恢复默认")) { model.hotkeySettings = .defaults }.controlSize(.small).disabled(model.hotkeySettings == .defaults)
                }
            }
            Section(lk("启动")) {
                Toggle(lk("登录 Mac 时打开 LayoutKeeper"),isOn:Binding(get:{ loginStatus.isOn },set:{ loginStatus=LoginItem.set($0) }))
                if let message=loginStatus.message {
                    HStack {
                        Text(message).font(.caption).foregroundStyle(Tone.warning.color)
                        Spacer()
                        if loginStatus == .requiresApproval { Button(lk("打开登录项")) { LoginItem.openLoginItemsSettings() }.controlSize(.small) }
                    }
                }
                Button(lk("重新打开使用引导…")) { model.openOnboarding?() }
            }
            Section(lk("跨桌面恢复")) {
                LabeledContent(lk("状态")) {
                    Label(model.crossSpaceSupport.enabled ? (model.crossSpaceSupport.isUntested ? lk("可用 · 未自检") : lk("可用")) : lk("不可用"),
                          systemImage:model.crossSpaceSupport.enabled ? (model.crossSpaceSupport.isUntested ? "checkmark.seal" : "checkmark.seal.fill") : "xmark.seal")
                        .foregroundStyle(model.crossSpaceSupport.enabled ? (model.crossSpaceSupport.isUntested ? Color.orange : Color.green) : Color.secondary)
                }
                Text(model.crossSpaceSupport.detail).font(.caption).foregroundStyle(.secondary)
                if model.crossSpaceSupport.isUntested { Button(lk("去运行一键自检")) { model.settingsTab = .diagnostics } }
            }
            Section(lk("权限")) {
                LabeledContent(lk("辅助功能")) {
                    Label(model.trusted ? lk("已授权") : lk("未授权"),systemImage:model.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.trusted ? Color.green : Color.orange)
                }
                if !model.trusted { Button(lk("打开系统设置")) { model.openControlSettings() } }
                Text(lk("只在你点击引导里的“打开系统设置”时才会弹出系统授权提示；这里只打开设置，不弹提示。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(lk("更新")) {
                Toggle(lk("自动检查更新"),isOn:$model.autoCheckUpdates)
                HStack {
                    Text(lk("每天检查一次。只连接 GitHub 获取版本信息和安装包，不发送任何个人数据。")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(lk("立即检查…")) { model.updater?.checkForUpdates() }.disabled(model.updater == nil && !RenderMode.snapshot)
                }
            }
            Section(lk("关于")) {
                LabeledContent(lk("版本"),value:version)
                LabeledContent(lk("系统"),value:"macOS \(model.systemBuildText)")
                LabeledContent(lk("安装位置")) {
                    HStack(spacing:8) {
                        if AppInstallation.isDevelopmentBuild(bundleURL:Bundle.main.bundleURL) {
                            Text(lk("开发构建")).font(.caption.weight(.medium)).foregroundStyle(Tone.warning.color)
                                .padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(Tone.warning.color.opacity(0.15)))
                        }
                        Text(AppInstallation.location(bundleURL:Bundle.main.bundleURL)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button(lk("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.controlSize(.small)
                    }
                }
                LabeledContent(lk("数据文件夹"),value:"~/Library/Application Support/LayoutKeeper")
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
                RestoreLogSection(model:model)
                GroupBox(lk("可保存窗口检查（只读）")) {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Button(model.checkingCapture ? lk("正在检查…") : lk("检查可保存窗口")) { model.inspectExternalCapture() }
                                .disabled(model.currentExternalMonitor==nil || !model.trusted || model.restoring || model.checkingCapture)
                            Spacer()
                        }
                        if !model.captureInspectionMessage.isEmpty { Text(model.captureInspectionMessage).font(.caption).foregroundStyle(.secondary) }
                        if let report=model.captureInspection ?? model.externalRecord?.captureReport { CaptureStatsView(model:model,report:report) }
                        if !model.externalMessage.isEmpty { Text(model.externalMessage).font(.caption).foregroundStyle(.secondary) }
                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                }
                GroupBox(lk("自动加减桌面（实验）")) {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Button(lk("检查调度中心结构（只读）")) { model.inspectMissionControl() }.disabled(!model.trusted || model.autoSpaces.running)
                            Button(lk("试一次：加一个桌面再删掉")) { model.runAutoSpacesTrial() }.disabled(!model.trusted || model.autoSpaces.running)
                        }
                        if !model.autoSpacesTrialMessage.isEmpty { Text(model.autoSpacesTrialMessage).font(.caption) }
                        if !model.missionControlReport.isEmpty {
                            Button(lk("复制结构到剪贴板")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.missionControlReport,forType:.string) }.controlSize(.small)
                            DisclosureGroup(lk("调度中心结构")) { Text(model.missionControlReport).font(.system(.caption2,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.font(.caption)
                        }
                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                }
                GroupBox(lk("技术信息")) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("\(model.accessState.title) · \(model.crossSpaceSupport.summary)").font(.caption)
                        HStack { Button(lk("刷新")) { model.refresh() }; Button(lk("导出诊断…")) { model.exportDiagnostic() } }
                        DisclosureGroup(lk("技术数据")) { Text(model.diagnostic).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.font(.caption)
                        DisclosureGroup(lk("上次操作详情")) {
                            ForEach(Array(model.externalRestoreResults.enumerated()),id:\.offset) { _,r in Text("\(r.outcome.rawValue) · \(r.detail)").font(.caption) }
                            Text(model.message).font(.caption).textSelection(.enabled)
                        }.font(.caption)
                        DisclosureGroup(lk("内存后端验证（不操作窗口）")) {
                            HStack { Button(lk("检查正常模拟")) { model.simulation(false) }; Button(lk("检查假成功应失败")) { model.simulation(true) } }
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
                Button(recording ? lk("按下新的快捷键…") : (model.hotkeySettings.keys[action]?.display ?? lk("未设置"))) { recording ? stop() : start() }
                    .font(.system(.body,design:.rounded).weight(.medium)).frame(minWidth:110)
                    .disabled(!model.hotkeySettings.enabled)
                if model.hotkeySettings.keys[action] != nil {
                    Button { model.hotkeySettings.keys[action]=nil } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help(lk("清除")).disabled(!model.hotkeySettings.enabled)
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

/// Diagnostics → 恢复记录: the last reconnects and restores (app IDs, counts and error codes only).
struct RestoreLogSection: View {
    @ObservedObject var model: Model
    @State private var lines: [String]=[]
    var body: some View {
        GroupBox(lk("恢复记录")) {
            VStack(alignment:.leading,spacing:8) {
                Text(lk("最近的接屏和恢复过程，只记录应用标识、数量和错误码，不含窗口标题。恢复没成功时，可以把这里的内容发给开发者。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if lines.isEmpty {
                    Text(lk("还没有记录")).font(.caption).foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        Text(lines.joined(separator:"\n")).font(.system(.caption2,design:.monospaced)).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(height:120)
                }
                HStack {
                    Button(lk("刷新")) { reload() }.controlSize(.small)
                    Button(lk("复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator:"\n"),forType:.string) }.controlSize(.small).disabled(lines.isEmpty)
                    if let url=model.restoreLog?.url,FileManager.default.fileExists(atPath:url.path) {
                        Button(lk("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                    }
                }
            }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
        }
        .onAppear { reload() }
    }
    private func reload() {
        lines=model.restoreLog?.tail(40) ?? (RenderMode.snapshot ? [
            "2026-10-14 21:43:20  reconnect: screens settled, layout=shared-external",
            "2026-10-14 21:43:20  reconnect: policy=auto",
            "2026-10-14 21:43:22  reconnect: windows settled",
            "2026-10-14 21:43:25  restore auto windows=5 [verified=4] failures=[com.example.editor:notResponding]",
            "2026-10-14 21:43:27  reconnect: retrying once for apps that did not respond",
            "2026-10-14 21:43:29  restore auto windows=5 [verified=1]"] : [])
    }
}

extension NotificationPermission {
    var blocksBanners: Bool { self == .denied || self == .alertsOff || self == .unavailable }
    var statusText: String {
        switch self {
        case .allowed: return lk("已允许通知")
        case .notDetermined: return lk("第一次需要提示时会请求通知权限")
        case .alertsOff: return lk("通知样式为「无」，不会弹出横幅；最近一条提示会显示在菜单栏菜单里。")
        case .denied: return lk("通知已关闭；最近一条提示会显示在菜单栏菜单里。")
        case .unavailable: return lk("当前构建无法使用系统通知；最近一条提示会显示在菜单栏菜单里。")
        }
    }
}

enum NotificationSettings {
    static func open() {
        let id=Bundle.main.bundleIdentifier ?? ""
        let pane=URL(string:"x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        if !NSWorkspace.shared.open(pane) { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
    }
}
