// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters

struct ActionNote: Equatable { var icon: String; var text: String; var tone: Tone
    static func == (a: ActionNote,b: ActionNote) -> Bool { a.icon==b.icon && a.text==b.text }
}

extension Model {
    static func slots(_ record: MonitorLayoutRecord?) -> [SpacesMiniMap.Slot] {
        guard let record else { return [] }
        let indexed=record.profile.windows.compactMap{ w in w.desktopIndex.map{($0,w)} }
        let count=max(record.coverage?.ordinaryDesktopCount ?? 0,indexed.map(\.0).max() ?? 0)
        guard count>0 else { return [] }
        return (1...min(count,9)).map { slot in
            SpacesMiniMap.Slot(id:slot,windows:indexed.filter{$0.0==slot}.map{ (bundleID:$0.1.selector.bundleID,frame:CGRect(x:$0.1.normalizedFrame.x,y:$0.1.normalizedFrame.y,width:$0.1.normalizedFrame.width,height:$0.1.normalizedFrame.height)) })
        }
    }
    var savedSubtitle: String {
        guard let record=displayRecord else { return selectedScreen == nil ? "连接外接屏后即可使用" : "还没有保存布局" }
        let c=ScreenLibrary.counts(record)
        return "保存于 \(RelativeTime.short(record.savedAt)) · \(c.windows) 个窗口" + (c.desktops>0 ? " · \(c.desktops) 个桌面" : "")
    }
    /// One status line at the bottom of the main window.
    var mainStatus: (icon: String,text: String,tone: Tone,needsPermission: Bool) {
        if !trusted { return ("exclamationmark.triangle.fill","需要辅助功能权限",.warning,true) }
        guard currentExternalMonitor != nil else { return ("display",externalMonitors.count>1 ? "目前只支持一块外接屏" : "未连接外接屏",.neutral,false) }
        if let note=actionNote { return (note.icon,note.text,note.tone,false) }
        if let r=lastRestoreSummary {
            var text="上次恢复 \(RelativeTime.clock(r.at)) · \(r.restored) 个窗口"
            if r.needsConfirmation>0 { text+=" · \(r.needsConfirmation) 个需确认" }
            if r.failed>0 { text+=" · \(r.failed) 个未通过" }
            return ("clock.arrow.circlepath",text,r.failed>0 || r.needsConfirmation>0 ? .warning : .neutral,false)
        }
        if let record=externalRecord,record.profile.windows.contains(where:{$0.desktopIndex==nil}) { return ("arrow.clockwise.circle.fill","布局来自旧版本，请重新保存一次",.warning,false) }
        if crossSpaceSupport.isUntested { return ("checkmark.seal","此系统版本建议在设置 → 诊断里自检一次",.neutral,false) }
        return ("checkmark.seal","接上屏幕时：\(currentExternalMonitor.flatMap{ monitorPreferences.restore($0.identity.key) }?.title ?? autoRestoreMode.title)",.neutral,false)
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing:0) {
            sidebar.frame(width:236)
            Divider()
            VStack(alignment:.leading,spacing:16) {
                if model.savedScreens.isEmpty { emptyState } else {
                    monitorCard
                    history
                }
                Spacer(minLength:0)
                Divider().opacity(0.5)
                statusRow
            }
            .padding(.horizontal,22).padding(.top,RenderMode.snapshot ? 20 : 34).padding(.bottom,18)
            .frame(maxWidth:.infinity)
        }
        .frame(width:900,height:700)
        .windowBackdrop()
        .onChange(of:model.currentExternalMonitor?.identity.key) { model.actionNote=nil }
    }

    // MARK: Sidebar
    private var sidebar: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:8) {
                Image(systemName:"rectangle.3.group.fill").font(.system(size:18,weight:.semibold))
                    .foregroundStyle(LinearGradient(colors:[Color.accentColor,Color.accentColor.opacity(0.6)],startPoint:.topLeading,endPoint:.bottomTrailing))
                Text("LayoutKeeper").font(.system(size:17,weight:.semibold,design:.rounded))
            }.padding(.horizontal,8)
            Text("已保存的屏幕").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,8)
            ScrollView {
                VStack(spacing:2) {
                    ForEach(model.savedScreens) { screen in screenRow(screen) }
                    if model.savedScreens.isEmpty {
                        Text("还没有保存的屏幕").font(.callout).foregroundStyle(.tertiary).frame(maxWidth:.infinity,alignment:.leading).padding(8)
                    }
                }
            }
            Spacer(minLength:0)
            Button { model.openSettings?(.general) } label: { Label("设置",systemImage:"gearshape").font(.callout) }
                .buttonStyle(.borderless).padding(.horizontal,8).help("设置")
        }
        .padding(.horizontal,10).padding(.top,RenderMode.snapshot ? 20 : 38).padding(.bottom,16)
        .frame(maxHeight:.infinity,alignment:.top)
        .background(Color.primary.opacity(0.035))
    }
    private func screenRow(_ screen: SavedScreen) -> some View {
        let selected=screen.key==model.selectedScreenKey
        let unsaved=Model.isUnsaved(screen)
        return Button { model.selectScreen(screen.key) } label: {
            HStack(alignment:.top,spacing:9) {
                Image(systemName:"display").font(.system(size:14)).foregroundStyle(screen.connected ? Color.accentColor : Color.secondary).frame(width:18).padding(.top,2)
                VStack(alignment:.leading,spacing:3) {
                    HStack(spacing:6) {
                        Text(screen.name).font(.body.weight(.medium)).lineLimit(1)
                        if screen.connected {
                            Text("当前").font(.system(size:10,weight:.semibold)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal,5).padding(.vertical,1).background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    Text(unsaved ? "还没有保存" : (screen.connected ? "" : "未连接 · ")+"保存于 \(RelativeTime.short(screen.savedAt))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength:0)
            }
            .padding(.horizontal,8).padding(.vertical,7)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(RoundedRectangle(cornerRadius:7,style:.continuous).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(Rectangle())
            .opacity(screen.connected ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名…") { model.renameScreen(screen.key) }
            if !unsaved { Divider(); Button("删除…") { model.deleteScreen(screen.key) } }
        }
    }

    // MARK: Card
    private var monitorCard: some View {
        let connected=model.selectedIsConnected
        let record=model.displayRecord
        let slots=Model.slots(record)
        return VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.center,spacing:12) {
                Image(systemName:connected ? "display" : "display.trianglebadge.exclamationmark")
                    .font(.system(size:20)).foregroundStyle(connected ? Color.accentColor : Color.secondary)
                    .frame(width:40,height:40).background(Circle().fill((connected ? Color.accentColor : Color.secondary).opacity(0.12)))
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:6) {
                        Text(model.selectedScreen?.name ?? "外接屏").font(.title3.weight(.semibold)).lineLimit(1)
                        if let key=model.selectedScreenKey {
                            Button { model.renameScreen(key) } label: { Image(systemName:"pencil").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).help("重命名这块屏幕，例如「公司」「家里」")
                        }
                    }
                    Text(model.savedSubtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength:6)
                if model.crossSpaceEnabled && connected && model.previewVersion == nil {
                    Label("支持跨桌面恢复",systemImage:"square.stack.3d.forward.dottedline")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal,8).padding(.vertical,4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help(model.crossSpaceSupport.detail)
                }
            }
            if !slots.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) { SpacesMiniMap(slots:slots,tileWidth:slots.count>4 ? 92 : 104) }
                    .frame(maxWidth:.infinity)
            } else {
                HStack(spacing:10) {
                    ForEach(1...3,id:\.self) { i in
                        VStack(spacing:5) {
                            RoundedRectangle(cornerRadius:7,style:.continuous).strokeBorder(style:StrokeStyle(lineWidth:1,dash:[4,3])).foregroundStyle(Color.secondary.opacity(0.4))
                                .frame(width:104,height:64)
                            Text("桌面 \(i)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }.frame(maxWidth:.infinity)
            }
            if let version=model.previewVersion { previewBar(version,connected:connected) }
            else if connected { stateLine(model.mainState); actions(model.mainState) }
            else { disconnectedActions }
        }
        .padding(18).card()
    }
    private func previewBar(_ version: LayoutVersion,connected: Bool) -> some View {
        let named=model.namedLayouts.first { $0.url == version.url }
        return HStack(spacing:10) {
            Label(named.map { "正在预览版式「\($0.name)」" } ?? "正在预览 \(RelativeTime.short(version.savedAt)) 的版本",systemImage:"eye").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("返回当前") { model.preview(nil) }
            if let named {
                Button { model.applyNamedLayout(named) } label: { Label("应用此版式",systemImage:"square.stack.3d.up") }.primaryButton().disabled(model.restoring || !connected)
            } else {
                Button { model.promote(version) } label: { Label("恢复此版本",systemImage:"clock.arrow.circlepath") }.primaryButton().disabled(model.restoring)
            }
        }.controlSize(.large)
    }
    private var disconnectedActions: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:6) {
                Image(systemName:"powerplug").foregroundStyle(.secondary)
                Text("这块屏幕未连接，接上后才能恢复或更新布局").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing:12) { restoreButton.buttonStyle(.bordered).disabled(true); saveButton.buttonStyle(.bordered).disabled(true) }.controlSize(.large)
        }
    }

    // MARK: 版式 + 历史版本
    private var history: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.firstTextBaseline) {
                        Text("版式").font(.headline)
                        Text("自己命名，一直保留").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button { model.saveAsNamedLayout(from:nil) } label: { Label("另存为版式…",systemImage:"plus") }
                            .controlSize(.small).disabled(model.displayRecord == nil)
                    }
                    if model.namedLayouts.isEmpty {
                        Text("把常用的摆法存成版式，例如「写代码」「开会」，之后一键切换").font(.callout).foregroundStyle(.tertiary).padding(.vertical,4)
                    } else {
                        rows(model.namedLayouts.map { AnyView(namedRow($0)) })
                    }
                }
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.firstTextBaseline) {
                        Text("历史版本").font(.headline)
                        Text("自动保留最近 5 个").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    if model.screenVersions.isEmpty {
                        Text("保存后，每次更新的旧布局都会出现在这里").font(.callout).foregroundStyle(.tertiary).padding(.vertical,4)
                    } else {
                        rows(model.screenVersions.map { AnyView(versionRow($0)) })
                    }
                }
            }
        }.frame(maxHeight:.infinity)
    }
    private func rows(_ views: [AnyView]) -> some View {
        VStack(spacing:0) {
            ForEach(Array(views.enumerated()),id:\.offset) { i,v in
                if i>0 { Divider().opacity(0.6) }
                v
            }
        }.card()
    }
    private func namedRow(_ l: NamedLayout) -> some View {
        let canApply=model.selectedIsConnected
        return HStack(spacing:10) {
            Image(systemName:"square.stack.3d.up.fill").foregroundStyle(l.isActive ? Color.accentColor : Color.secondary).frame(width:16)
            Text(l.name).font(.callout.weight(.medium)).frame(minWidth:80,alignment:.leading)
            Text("\(l.windowCount) 个窗口" + (l.desktopCount>0 ? " · \(l.desktopCount) 个桌面" : "")).font(.callout).foregroundStyle(.secondary)
            if l.isActive { Text("当前").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
            Spacer()
            Button(model.previewVersion?.url == l.url ? "预览中" : "预览") { model.preview(LayoutVersion(url:l.url,savedAt:l.savedAt,windowCount:l.windowCount,desktopCount:l.desktopCount,isCurrent:false,label:l.name)) }
                .disabled(l.isActive || model.previewVersion?.url == l.url)
            Button("应用") { model.applyNamedLayout(l) }.disabled(!canApply || l.isActive || model.restoring)
                .help(canApply ? "设为当前布局并把窗口摆回去，可撤销" : "这块屏幕未连接")
        }
        .controlSize(.small).padding(.horizontal,12).padding(.vertical,7)
        .contextMenu {
            Button("应用") { model.applyNamedLayout(l) }.disabled(!canApply)
            Button("重命名…") { model.renameNamedLayout(l) }
            Divider()
            Button("删除…") { model.deleteNamedLayout(l) }
        }
    }
    private func versionRow(_ v: LayoutVersion) -> some View {
        let previewing=model.previewVersion == v || (v.isCurrent && model.previewVersion == nil)
        return HStack(spacing:10) {
            Image(systemName:v.isCurrent ? "checkmark.circle.fill" : (v.label != nil ? "tag" : "clock")).foregroundStyle(v.isCurrent ? Tone.success.color : Color.secondary).frame(width:16)
            Text(RelativeTime.short(v.savedAt)).font(.callout.monospacedDigit()).frame(width:96,alignment:.leading)
            if let label=v.label { Text(label).font(.callout.weight(.medium)) } else { originTag(v.originName) }
            Text("\(v.windowCount) 个窗口" + (v.desktopCount>0 ? " · \(v.desktopCount) 个桌面" : "")).font(.callout).foregroundStyle(.secondary)
            if v.isCurrent { Text("当前").font(.caption.weight(.semibold)).foregroundStyle(Tone.success.color) }
            Spacer()
            if !v.isCurrent {
                Button(previewing ? "预览中" : "预览") { model.preview(v) }.disabled(previewing)
                Button("恢复此版本") { model.promote(v) }.disabled(model.restoring)
            } else if model.previewVersion != nil {
                Button("返回当前") { model.preview(nil) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal,12).padding(.vertical,7)
        .background(previewing && !v.isCurrent ? Color.accentColor.opacity(0.08) : .clear)
        .contextMenu {
            Button("重命名…") { model.labelVersion(v) }.disabled(v.isCurrent)
            Button("另存为版式…") { model.saveAsNamedLayout(from:v.url) }
        }
    }

    /// 「来自：写代码」 for versions that came from a 版式; a subtler 「手动保存」 otherwise.
    @ViewBuilder private func originTag(_ origin: String?) -> some View {
        if let origin {
            Label("来自：\(origin)",systemImage:"square.stack.3d.up").labelStyle(.titleAndIcon).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                .padding(.horizontal,6).padding(.vertical,2).background(Capsule().fill(Color.accentColor.opacity(0.12)))
        } else {
            Text("手动保存").font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal,6).padding(.vertical,2).background(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
        }
    }

    // MARK: Empty state
    private var emptyState: some View {
        VStack(spacing:12) {
            Spacer()
            Image(systemName:"display.2").font(.system(size:44)).foregroundStyle(.secondary)
            Text("还没有保存的屏幕").font(.title3.weight(.semibold))
            Text("接上外接屏，把窗口摆好后点「保存布局」。\n之后每次接上这块屏幕，都能一键恢复。").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth:.infinity)
    }
    @ViewBuilder private func stateLine(_ state: MainWindowState) -> some View {
        switch state {
        case .differs(let ready,let confirm):
            HStack(spacing:6) {
                Circle().fill(Tone.success.color).frame(width:7,height:7)
                Text(ready>0 ? "\(ready) 个窗口不在保存的位置" : "窗口位置和保存的不同").font(.callout)
                if confirm>0 { Text("· \(confirm) 个需确认").font(.callout).foregroundStyle(Tone.warning.color) }
            }
        case .matches(let missing):
            HStack(spacing:6) {
                Image(systemName:"checkmark.circle.fill").foregroundStyle(Tone.success.color)
                Text("已是保存的布局").font(.callout)
                if missing>0 { Text("· \(missing) 个窗口未打开或无法恢复").font(.callout).foregroundStyle(.secondary) }
            }
        case .checking:
            HStack(spacing:6) { ProgressView().controlSize(.mini); Text("正在对比当前窗口…").font(.callout).foregroundStyle(.secondary) }
        default: EmptyView()
        }
    }
    @ViewBuilder private func actions(_ state: MainWindowState) -> some View {
        let canSave=model.quickBlocker(needsLayout:false) == nil
        let canRestore=model.quickBlocker(needsLayout:true) == nil
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                switch state.primary {
                case .save:
                    saveButton.primaryButton().disabled(!canSave)
                case .restore:
                    restoreButton.primaryButton().disabled(!canRestore)
                    saveButton.buttonStyle(.bordered).disabled(!canSave)
                case .none:
                    if case .matches = state {
                        Label("已是保存的布局",systemImage:"checkmark").font(.body.weight(.medium)).foregroundStyle(Tone.success.color)
                            .frame(maxWidth:.infinity).padding(.vertical,8)
                            .background(RoundedRectangle(cornerRadius:8,style:.continuous).fill(Tone.success.color.opacity(0.12)))
                        saveButton.buttonStyle(.bordered).disabled(!canSave)
                    } else {
                        restoreButton.buttonStyle(.bordered).disabled(true)
                        saveButton.buttonStyle(.bordered).disabled(true)
                    }
                }
            }.controlSize(.large)
            if model.externalRecord != nil && canRestore && state.primary != .none {
                Button { model.openPreviewPanel?(true) } label: { Label("先预览，再恢复…",systemImage:"eye").font(.callout) }.buttonStyle(.link)
            }
        }
    }
    private var saveButton: some View {
        Button { model.saveExternalLayout(); model.requestLiveCheck?() } label: {
            Label("保存布局",systemImage:"square.and.arrow.down").frame(maxWidth:.infinity).padding(.vertical,4)
        }
    }
    private var restoreButton: some View {
        Button { model.quickRestore() } label: {
            Label("恢复布局",systemImage:"arrow.uturn.backward.circle").frame(maxWidth:.infinity).padding(.vertical,4)
        }
    }
    private var statusRow: some View {
        let s=model.mainStatus
        return HStack(spacing:8) {
            Image(systemName:s.icon).foregroundStyle(s.tone.color)
            Text(s.text).font(.callout).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
            Spacer()
            if s.needsPermission { Button("打开设置") { model.openControlSettings() }.controlSize(.small) }
            else if model.lastRestoreJournal?.canUndo == true {
                Button("撤销") { model.quickUndo() }.buttonStyle(.link).disabled(!model.trusted || model.restoring)
            }
        }
    }
}
