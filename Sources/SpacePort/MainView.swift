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
    var savedSlots: [SpacesMiniMap.Slot] {
        guard let record=externalRecord else { return [] }
        let indexed=record.profile.windows.compactMap{ w in w.desktopIndex.map{($0,w)} }
        let count=max(record.coverage?.ordinaryDesktopCount ?? 0,indexed.map(\.0).max() ?? 0)
        guard count>0 else { return [] }
        return (1...min(count,9)).map { slot in
            SpacesMiniMap.Slot(id:slot,windows:indexed.filter{$0.0==slot}.map{ (bundleID:$0.1.selector.bundleID,frame:CGRect(x:$0.1.normalizedFrame.x,y:$0.1.normalizedFrame.y,width:$0.1.normalizedFrame.width,height:$0.1.normalizedFrame.height)) })
        }
    }
    var savedSubtitle: String {
        guard let record=externalRecord else { return currentExternalMonitor == nil ? "连接外接屏后即可使用" : "还没有保存布局" }
        let desktops=Set(record.profile.windows.compactMap(\.desktopIndex)).count
        return "保存于 \(RelativeTime.short(record.savedAt)) · \(record.profile.windows.count) 个窗口" + (desktops>0 ? " · \(desktops) 个桌面" : "")
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
        if let until=pausedUntil,Date()<until { return ("pause.circle","自动恢复已暂停至 \(RelativeTime.clock(until))",.neutral,false) }
        if crossSpaceSupport.isUntested { return ("checkmark.seal","此系统版本建议在设置 → 诊断里自检一次",.neutral,false) }
        return ("checkmark.seal","接上屏幕时：\(currentExternalMonitor.flatMap{ monitorPreferences.restore($0.identity.key) }?.title ?? autoRestoreMode.title)",.neutral,false)
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    @State private var editingName=false
    @State private var draftName=""
    var body: some View {
        let state=model.mainState
        VStack(alignment:.leading,spacing:18) {
            header
            monitorCard(state)
            actions(state)
            Divider().opacity(0.5)
            statusRow
        }
        .padding(.horizontal,24).padding(.top,RenderMode.snapshot ? 22 : 34).padding(.bottom,20)
        .frame(width:540)
        .windowBackdrop()
        .onChange(of:model.currentExternalMonitor?.identity.key) { model.actionNote=nil; editingName=false }
    }
    private var header: some View {
        HStack(spacing:10) {
            Image(systemName:"rectangle.3.group.fill").font(.system(size:20,weight:.semibold))
                .foregroundStyle(LinearGradient(colors:[Color.accentColor,Color.accentColor.opacity(0.6)],startPoint:.topLeading,endPoint:.bottomTrailing))
            Text("LayoutKeeper").font(.system(size:20,weight:.semibold,design:.rounded))
            Spacer()
            Button { model.openSettings?(.general) } label: { Image(systemName:"gearshape").font(.system(size:15)) }
                .buttonStyle(.borderless).help("设置")
        }
    }
    private func monitorCard(_ state: MainWindowState) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.center,spacing:12) {
                Image(systemName:model.currentExternalMonitor == nil ? "display.trianglebadge.exclamationmark" : "display")
                    .font(.system(size:20)).foregroundStyle(Color.accentColor)
                    .frame(width:40,height:40).background(Circle().fill(Color.accentColor.opacity(0.12)))
                VStack(alignment:.leading,spacing:2) {
                    nameView
                    Text(model.savedSubtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength:6)
                if model.crossSpaceEnabled && model.currentExternalMonitor != nil {
                    Label("支持跨桌面恢复",systemImage:"square.stack.3d.forward.dottedline")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal,8).padding(.vertical,4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help(model.crossSpaceSupport.detail)
                }
            }
            if !model.savedSlots.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) { SpacesMiniMap(slots:model.savedSlots,tileWidth:model.savedSlots.count>4 ? 92 : 104) }
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
            stateLine(state)
        }
        .padding(18).card()
    }
    @ViewBuilder private var nameView: some View {
        if let monitor=model.currentExternalMonitor {
            if editingName {
                HStack(spacing:6) {
                    TextField(monitor.identity.name,text:$draftName,onCommit:commitName).textFieldStyle(.roundedBorder).frame(maxWidth:200)
                    Button("完成",action:commitName).controlSize(.small)
                }
            } else {
                HStack(spacing:6) {
                    Text(model.monitorPreferences.displayName(monitor.identity)).font(.title3.weight(.semibold)).lineLimit(1)
                    Button { draftName=model.monitorPreferences.entries[monitor.identity.key]?.displayName ?? ""; editingName=true } label: {
                        Image(systemName:"pencil").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                    }.buttonStyle(.borderless).help("给这块屏幕起个名字，例如「公司」「家里」（\(monitor.identity.name)）")
                }
            }
        } else {
            Text("没有外接屏").font(.title3.weight(.semibold))
        }
    }
    private func commitName() {
        if let m=model.currentExternalMonitor { model.monitorPreferences.setDisplayName(draftName,for:m.identity.key,seenName:m.identity.name) }
        editingName=false
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
