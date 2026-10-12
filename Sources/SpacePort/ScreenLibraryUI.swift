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
        guard let record=try? MonitorLayoutStore.load(from:version.url) else { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:"这个版本无法读取",tone:.warning); return }
        previewVersion=version; previewRecord=record
    }
    /// Makes an older version current. Confirmed first; the replaced current version goes to history and can be put back with 撤销.
    func promote(_ version: LayoutVersion) {
        guard let library=screenLibrary,let key=selectedScreenKey,!version.isCurrent,!restoring else { return }
        let canApply=selectedIsConnected && quickBlocker(needsLayout:false) == nil
        let alert=NSAlert(); alert.messageText="恢复 \(RelativeTime.short(version.savedAt)) 的版本？"
        alert.informativeText="它会成为这块屏幕的当前布局（\(version.windowCount) 个窗口），现在的布局存入历史版本，可以撤销。" + (canApply ? "" : "\n这块屏幕现在没有连接，只改保存的布局，不移动窗口。")
        if canApply { alert.addButton(withTitle:"设为当前并恢复窗口") }
        alert.addButton(withTitle:"仅设为当前"); alert.addButton(withTitle:"取消")
        let answer=alert.runModal()
        let apply=canApply && answer == .alertFirstButtonReturn
        guard apply || answer == (canApply ? .alertSecondButtonReturn : .alertFirstButtonReturn) else { return }
        do {
            let replaced=try library.promote(version.url,key:key)
            previewVersion=nil; previewRecord=nil
            refreshExternalMonitor()
            showToast?(Toast(icon:"clock.arrow.circlepath",tone:.success,title:"已恢复 \(RelativeTime.short(version.savedAt)) 的版本",detail:"原来的布局已存入历史版本",
                             actions:replaced.map { url in [Toast.Action(title:"撤销") { [weak self] in self?.undoPromote(url,key:key) }] } ?? [],duration:6))
            if apply { quickRestore() }
        } catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:"没有恢复这个版本：\(error)",tone:.warning) }
    }
    private func undoPromote(_ url: URL,key: String) {
        guard let library=screenLibrary else { return }
        do { try library.promote(url,key:key); refreshExternalMonitor(); actionNote=ActionNote(icon:"arrow.uturn.backward",text:"已撤销，当前布局已换回",tone:.neutral) }
        catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:"无法撤销：\(error)",tone:.warning) }
    }
    func deleteScreen(_ key: String) {
        guard let library=screenLibrary,let screen=savedScreens.first(where:{ $0.key==key }),!Self.isUnsaved(screen) else { return }
        let alert=NSAlert(); alert.messageText="删除「\(screen.name)」的布局？"
        alert.informativeText="当前布局和全部历史版本会移到 LayoutKeeper 的回收站，可以马上撤销。不会移动任何窗口。"
        alert.addButton(withTitle:"删除"); alert.addButton(withTitle:"取消")
        alert.buttons.first?.hasDestructiveAction=true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let bin=try library.delete(key)
            if selectedScreenKey==key { selectedScreenKey=nil }
            refreshExternalMonitor()
            showToast?(Toast(icon:"trash",tone:.neutral,title:"已删除「\(screen.name)」",detail:"布局已移到回收站",
                             actions:[Toast.Action(title:"撤销") { [weak self] in self?.undoDelete(bin,key:key) }],duration:8))
        } catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:"没有删除：\(error)",tone:.warning) }
    }
    private func undoDelete(_ bin: URL,key: String) {
        guard let library=screenLibrary else { return }
        do { try library.undoDelete(bin,key:key); selectedScreenKey=key; refreshExternalMonitor(); actionNote=ActionNote(icon:"arrow.uturn.backward",text:"已恢复删除的布局",tone:.neutral) }
        catch { actionNote=ActionNote(icon:"exclamationmark.triangle.fill",text:"无法撤销删除（\(error)），文件仍在回收站",tone:.warning) }
    }
    // Design stage (0.6 mockups): 版式 actions are stubbed until the design is approved.
    func saveAsNamedLayout(from url: URL?) { actionNote=ActionNote(icon:"paintbrush",text:"设计稿：「另存为版式」尚未接线",tone:.neutral) }
    func applyNamedLayout(_ layout: NamedLayout) { actionNote=ActionNote(icon:"paintbrush",text:"设计稿：「应用」尚未接线",tone:.neutral) }
    func renameNamedLayout(_ layout: NamedLayout) { actionNote=ActionNote(icon:"paintbrush",text:"设计稿：重命名尚未接线",tone:.neutral) }
    func deleteNamedLayout(_ layout: NamedLayout) { actionNote=ActionNote(icon:"paintbrush",text:"设计稿：删除尚未接线",tone:.neutral) }
    func labelVersion(_ v: LayoutVersion) { actionNote=ActionNote(icon:"paintbrush",text:"设计稿：重命名尚未接线",tone:.neutral) }
    func renameScreen(_ key: String) {
        guard let screen=savedScreens.first(where:{ $0.key==key }) else { return }
        let alert=NSAlert(); alert.messageText="重命名屏幕"
        alert.informativeText="例如「公司」「家里」。留空则使用屏幕自带的名字（\(screen.monitor.name)）。"
        let field=NSTextField(frame:NSRect(x:0,y:0,width:240,height:24))
        field.stringValue=monitorPreferences.entries[key]?.displayName ?? ""; field.placeholderString=screen.monitor.name
        alert.accessoryView=field
        alert.addButton(withTitle:"好"); alert.addButton(withTitle:"取消")
        alert.window.initialFirstResponder=field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitorPreferences.setDisplayName(field.stringValue,for:key,seenName:screen.monitor.name)
        reloadLibrary()
    }
}
