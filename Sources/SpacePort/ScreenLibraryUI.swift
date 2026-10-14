// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore

/// Saved screens and their version history (sidebar + 「历史版本」). Only layout files are touched here;
/// windows move only through the existing restore path, which still requires the screen to be connected.
extension Model {
    var screenLibrary: ScreenLibrary? { layoutDirectory.map { ScreenLibrary(root:$0.appendingPathComponent("screens",isDirectory:true)) } }
    var selectedScreen: SavedScreen? { savedScreens.first { $0.key==selectedScreenKey } }
    var selectedIsConnected: Bool { selectedScreen?.connected == true && selectedScreenKey == currentExternalMonitor?.identity.key }
    /// The record the card shows: a previewed version, else the selected screen's current layout.
    var displayRecord: MonitorLayoutRecord? { previewRecord ?? (selectedIsConnected ? externalRecord : selectedRecord) }
    static func isUnsaved(_ s: SavedScreen) -> Bool { s.savedAt == .distantPast }

    func reloadLibrary() {
        guard !RenderMode.snapshot,let library=screenLibrary else { return }
        let connected=currentExternalMonitor?.identity
        var list=library.screens(connectedKey:connected?.key) { [monitorPreferences] in monitorPreferences.displayName($0) }
        if let connected,!list.contains(where:{ $0.key==connected.key }) {
            list.insert(SavedScreen(key:connected.key,monitor:connected,name:monitorPreferences.displayName(connected),savedAt:.distantPast,windowCount:0,desktopCount:0,connected:true),at:0)
        }
        savedScreens=list
        if selectedScreenKey == nil || !list.contains(where:{ $0.key==selectedScreenKey }) { selectedScreenKey=connected?.key ?? list.first?.key; previewVersion=nil; previewRecord=nil }
        loadSelected()
    }
    func selectScreen(_ key: String) {
        guard key != selectedScreenKey else { return }
        selectedScreenKey=key; previewVersion=nil; previewRecord=nil; actionNote=nil
        loadSelected()
    }
    private func loadSelected() {
        guard let library=screenLibrary,let key=selectedScreenKey else { screenVersions=[]; selectedRecord=nil; return }
        screenVersions=library.versions(key); namedLayouts=library.namedLayouts(key)
        selectedRecord=try? MonitorLayoutStore.load(from:library.currentURL(key))
        if let p=previewVersion,!screenVersions.contains(p) { previewVersion=nil; previewRecord=nil }
    }
    func preview(_ version: LayoutVersion?) {
        guard let version,!version.isCurrent else { previewVersion=nil; previewRecord=nil; return }
        guard let record=try? MonitorLayoutStore.load(from:version.url) else { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("这个版本无法读取"),tone:.warning); return }
        previewVersion=version; previewRecord=record
    }
    /// Makes an older version current. Confirmed first; the replaced current version goes to history and can be put back with 撤销.
    func promote(_ version: LayoutVersion) {
        guard let library=screenLibrary,let key=selectedScreenKey,!version.isCurrent,!restoring else { return }
        let canApply=selectedIsConnected && quickBlocker(needsLayout:false) == nil
        let alert=NSAlert(); alert.messageText=lk("恢复 %@ 的版本？", "\(RelativeTime.short(version.savedAt))")
        alert.informativeText=lk("它会成为这块屏幕的当前布局（%@ 个窗口），现在的布局存入历史版本，可以撤销。", "\(version.windowCount)") + (canApply ? "" : lk("\n这块屏幕现在没有连接，只改保存的布局，不移动窗口。"))
        if canApply { alert.addButton(withTitle:lk("设为当前并恢复窗口")) }
        alert.addButton(withTitle:lk("仅设为当前")); alert.addButton(withTitle:lk("取消"))
        let answer=alert.runModal()
        let apply=canApply && answer == .alertFirstButtonReturn
        guard apply || answer == (canApply ? .alertSecondButtonReturn : .alertFirstButtonReturn) else { return }
        do {
            let replaced=try library.promote(version.url,key:key)
            previewVersion=nil; previewRecord=nil
            refreshExternalMonitor()
            showToast?(Toast(icon:"clock.arrow.circlepath",tone:.success,title:lk("已恢复 %@ 的版本", "\(RelativeTime.short(version.savedAt))"),detail:lk("原来的布局已存入历史版本"),
                             actions:replaced.map { url in [Toast.Action(title:lk("撤销")) { [weak self] in self?.undoPromote(url,key:key) }] } ?? [],duration:6))
            if apply { quickRestore() }
        } catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("没有恢复这个版本：%@", "\(error)"),tone:.warning) }
    }
    private func undoPromote(_ url: URL,key: String) {
        guard let library=screenLibrary else { return }
        do { try library.promote(url,key:key); refreshExternalMonitor(); actionNote=ActionNote(icon:"arrow.uturn.backward",text:lk("已撤销，当前布局已换回"),tone:.neutral) }
        catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("无法撤销：%@", "\(error)"),tone:.warning) }
    }
    func deleteScreen(_ key: String) {
        guard let library=screenLibrary,let screen=savedScreens.first(where:{ $0.key==key }),!Self.isUnsaved(screen) else { return }
        let alert=NSAlert(); alert.messageText=lk("删除「%@」的布局？", "\(screen.name)")
        alert.informativeText=lk("当前布局和全部历史版本会移到 LayoutKeeper 的回收站，可以马上撤销。不会移动任何窗口。")
        alert.addButton(withTitle:lk("删除")); alert.addButton(withTitle:lk("取消"))
        alert.buttons.first?.hasDestructiveAction=true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let bin=try library.delete(key)
            if selectedScreenKey==key { selectedScreenKey=nil }
            refreshExternalMonitor()
            showToast?(Toast(icon:"trash",tone:.neutral,title:lk("已删除「%@」", "\(screen.name)"),detail:lk("布局已移到回收站"),
                             actions:[Toast.Action(title:lk("撤销")) { [weak self] in self?.undoDelete(bin,key:key) }],duration:8))
        } catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("没有删除：%@", "\(error)"),tone:.warning) }
    }
    private func undoDelete(_ bin: URL,key: String) {
        guard let library=screenLibrary else { return }
        do { try library.undoDelete(bin,key:key); selectedScreenKey=key; refreshExternalMonitor(); actionNote=ActionNote(icon:"arrow.uturn.backward",text:lk("已恢复删除的布局"),tone:.neutral) }
        catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("无法撤销删除（%@），文件仍在回收站", "\(error)"),tone:.warning) }
    }
    // MARK: 版式 (named layouts)
    private func fail(_ text: String,_ error: Error) { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:lk("%@：%@", "\(text)", "\(error)"),tone:.warning) }
    /// Single-line text prompt; nil when cancelled.
    private func ask(_ title: String,_ info: String,value: String,placeholder: String,ok: String) -> String? {
        let alert=NSAlert(); alert.messageText=title; alert.informativeText=info
        let field=NSTextField(frame:NSRect(x:0,y:0,width:240,height:24)); field.stringValue=value; field.placeholderString=placeholder
        alert.accessoryView=field; alert.addButton(withTitle:ok); alert.addButton(withTitle:lk("取消"))
        alert.window.initialFirstResponder=field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    /// Saves the current layout (or the previewed / given history version) as a named layout.
    func saveAsNamedLayout(from url: URL?) {
        guard let library=screenLibrary,let key=selectedScreenKey else { return }
        let source=url ?? previewVersion?.url ?? library.currentURL(key)
        guard let name=ask(lk("另存为版式"),lk("给这套摆法起个名字，例如「写代码」「开会」。版式会一直保留，可以随时一键切换。"),value:"",placeholder:lk("版式 %@", "\(namedLayouts.count+1)"),ok:lk("保存")) else { return }
        let finalName=name.trimmingCharacters(in:.whitespaces).isEmpty ? lk("版式 %@", "\(namedLayouts.count+1)") : name
        do { try library.saveNamed(from:source,key:key,name:finalName); reloadLibrary(); actionNote=ActionNote(icon:"square.stack.3d.up.fill",text:lk("已存为版式「%@」", "\(finalName)"),tone:.success) }
        catch { fail(lk("没有保存版式"),error) }
    }
    /// One click: make the 版式 current (it becomes the default for auto-restore) and, when connected, put the windows back. 撤销 reverts both.
    func applyNamedLayout(_ layout: NamedLayout,key explicitKey: String? = nil) {
        guard let library=screenLibrary,let key=explicitKey ?? selectedScreenKey,!restoring else { return }
        guard key == currentExternalMonitor?.identity.key else { actionNote=ActionNote(icon:"powerplug",text:lk("这块屏幕未连接，接上后才能应用版式"),tone:.neutral); return }
        do {
            let undo=try library.apply(layout.url,key:key)
            previewVersion=nil; previewRecord=nil
            refreshExternalMonitor()
            let journalBefore=lastRestoreJournal?.id
            var detail=lk("已设为当前布局")
            if quickBlocker(needsLayout:true) == nil {
                let o=directRestore(.manual)
                detail=o.error ?? lk("已恢复 %@ 个窗口", "\(o.restored)") + (o.needsConfirmation>0 ? lk(" · %@ 个需确认", "\(o.needsConfirmation)") : "")
            }
            let moved=lastRestoreJournal?.id != journalBefore && lastRestoreJournal?.canUndo == true
            showToast?(Toast(icon:"square.stack.3d.up.fill",tone:.success,title:lk("已切换到「%@」", "\(layout.name)"),detail:detail,
                             actions:undo.map { url in [Toast.Action(title:lk("撤销")) { [weak self] in self?.undoApply(url,key:key,undoWindows:moved) }] } ?? [],duration:6))
        } catch { fail(lk("没有应用版式"),error) }
    }
    private func undoApply(_ url: URL,key: String,undoWindows: Bool) {
        guard let library=screenLibrary else { return }
        do {
            try library.apply(url,key:key); refreshExternalMonitor()
            if undoWindows,lastRestoreJournal?.canUndo == true { quickUndo() }
            actionNote=ActionNote(icon:"arrow.uturn.backward",text:lk("已撤销切换"),tone:.neutral)
        } catch { fail(lk("无法撤销"),error) }
    }
    /// Menu bar 「切换版式」: the connected screen's named layouts, in the same order as the menu.
    func applyConnectedLayout(at index: Int) {
        guard let key=currentExternalMonitor?.identity.key,let library=screenLibrary else { return }
        let list=library.namedLayouts(key)
        guard list.indices.contains(index) else { return }
        applyNamedLayout(list[index],key:key)
    }
    func renameNamedLayout(_ layout: NamedLayout) {
        guard let library=screenLibrary,let key=selectedScreenKey,
              let name=ask(lk("重命名版式"),"",value:layout.name,placeholder:layout.name,ok:lk("好")) else { return }
        do { try library.renameNamed(layout.url,key:key,name:name); reloadLibrary() } catch { fail(lk("没有重命名"),error) }
    }
    func deleteNamedLayout(_ layout: NamedLayout) {
        guard let library=screenLibrary,let key=selectedScreenKey else { return }
        let alert=NSAlert(); alert.messageText=lk("删除版式「%@」？", "\(layout.name)")
        alert.informativeText=lk("版式会移到 LayoutKeeper 的回收站，可以马上撤销。当前布局和窗口不受影响。")
        alert.addButton(withTitle:lk("删除")); alert.addButton(withTitle:lk("取消")); alert.buttons.first?.hasDestructiveAction=true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let bin=try library.deleteNamed(layout.url,key:key); reloadLibrary()
            showToast?(Toast(icon:"trash",tone:.neutral,title:lk("已删除版式「%@」", "\(layout.name)"),actions:[Toast.Action(title:lk("撤销")) { [weak self] in
                do { try library.undoDeleteNamed(bin,key:key); self?.reloadLibrary() } catch { self?.fail(lk("无法撤销删除（文件仍在回收站）"),error) }
            }],duration:8))
        } catch { fail(lk("没有删除"),error) }
    }
    /// Labels a history version; a labelled version stays in history and is never auto-pruned. Empty clears the label.
    func labelVersion(_ v: LayoutVersion) {
        guard !v.isCurrent,let library=screenLibrary,let key=selectedScreenKey,
              let label=ask(lk("重命名历史版本"),lk("加上名字后，这个版本会一直保留在历史版本里，不会被自动清理。留空则取消名字。"),value:v.label ?? "",placeholder:RelativeTime.short(v.savedAt),ok:lk("好")) else { return }
        do { try library.labelVersion(v.url,key:key,label:label); reloadLibrary() } catch { fail(lk("没有重命名"),error) }
    }
    func renameScreen(_ key: String) {
        guard let screen=savedScreens.first(where:{ $0.key==key }) else { return }
        let alert=NSAlert(); alert.messageText=lk("重命名屏幕")
        alert.informativeText=lk("例如「公司」「家里」。留空则使用屏幕自带的名字（%@）。", "\(screen.monitor.name)")
        let field=NSTextField(frame:NSRect(x:0,y:0,width:240,height:24))
        field.stringValue=monitorPreferences.entries[key]?.displayName ?? ""; field.placeholderString=screen.monitor.name
        alert.accessoryView=field
        alert.addButton(withTitle:lk("好")); alert.addButton(withTitle:lk("取消"))
        alert.window.initialFirstResponder=field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitorPreferences.setDisplayName(field.stringValue,for:key,seenName:screen.monitor.name)
        reloadLibrary()
    }
}
