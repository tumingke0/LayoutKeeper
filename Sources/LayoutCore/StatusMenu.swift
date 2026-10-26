// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// One description of the menu-bar menu, used both by the real NSMenu and by the snapshot renderer.
public struct MenuItemModel: Equatable, Identifiable {
    public enum Kind: Equatable { case status, action, separator, submenu }
    public var kind: Kind
    public var id: String
    public var title: String
    public var symbol: String?
    public var enabled=true
    public var reason: String?
    public var hotkey: Hotkey?
    /// Standard menu key equivalent that only works while the menu is open (e.g. ⌘, / ⌘Q).
    public var menuKey: String?
    public var checked=false
    public var children: [MenuItemModel]=[]
    public init(kind: Kind,id: String,title: String,symbol: String? = nil,enabled: Bool = true,reason: String? = nil,hotkey: Hotkey? = nil,menuKey: String? = nil,checked: Bool = false,children: [MenuItemModel] = []) {
        self.kind=kind; self.id=id; self.title=title; self.symbol=symbol; self.enabled=enabled; self.reason=reason; self.hotkey=hotkey; self.menuKey=menuKey; self.checked=checked; self.children=children
    }
    public static func separator(_ id: String) -> MenuItemModel { MenuItemModel(kind:.separator,id:id,title:"") }
    public var shortcutText: String? { hotkey?.display ?? menuKey.map{"⌘"+$0.uppercased()} }
}

/// A named layout (版式) of the connected screen, as listed in the 「切换版式」 submenu.
public struct MenuLayout: Equatable {
    public var name: String
    public var active: Bool
    public init(name: String,active: Bool) { self.name=name; self.active=active }
}

/// The 「显示器排列」 submenu. nil hides it (fewer than two displays and no presets).
public struct ArrangementMenu: Equatable {
    public struct Entry: Equatable {
        public var id: String
        public var name: String
        public var active: Bool
        public var hotkey: Hotkey?
        /// Why it can't be applied right now (mirroring, asleep…); nil = can be applied.
        public var blocked: String?
        public init(id: String,name: String,active: Bool,hotkey: Hotkey? = nil,blocked: String? = nil) { self.id=id; self.name=name; self.active=active; self.hotkey=hotkey; self.blocked=blocked }
    }
    /// 「外接屏在正上方 / 正右方 / 正下方 / 正左方」 (centred), MacBook screen + one external monitor.
    public struct Quick: Equatable {
        public var edge: ArrangementEdge
        /// The external monitor sits on this edge now (any alignment).
        public var active: Bool
        public init(edge: ArrangementEdge,active: Bool) { self.edge=edge; self.active=active }
    }
    public var quick: [Quick]=[]
    /// Why the quick options are unavailable (two external monitors, mirroring…); nil = available.
    public var quickBlock: String?
    /// Custom presets made for the displays connected now (those equal to a quick option are left out).
    public var entries: [Entry]
    /// Presets made for other display combinations (not listed).
    public var otherCount: Int
    /// Why the current arrangement can't be saved (nil = it can).
    public struct PortBinding: Equatable, Sendable {
        public var portID: String
        public var portLabel: String
        public var boundName: String?
        public var currentName: String?
        public var activeIsBound: Bool
        public init(portID: String,portLabel: String,boundName: String?,currentName: String?,activeIsBound: Bool) {
            self.portID=portID; self.portLabel=portLabel; self.boundName=boundName; self.currentName=currentName; self.activeIsBound=activeIsBound
        }
    }
    public var saveBlock: String?
    /// Something blocks every switch (a confirmation is open, windows are being restored…).
    public var busy: String?
    public var portBinding: PortBinding?
    public init(quick: [Quick] = [],quickBlock: String? = nil,entries: [Entry] = [],otherCount: Int = 0,saveBlock: String? = nil,busy: String? = nil,portBinding: PortBinding? = nil) {
        self.quick=quick; self.quickBlock=quickBlock; self.entries=entries; self.otherCount=otherCount; self.saveBlock=saveBlock; self.busy=busy; self.portBinding=portBinding
    }
}

public struct MenuState {
    public var arrangement: ArrangementMenu?
    public var layouts: [MenuLayout]=[]
    public var monitorName: String?
    public var windowCount: Int?
    public var savedAt: Date?
    public var trusted=true
    public var busy=false
    public var canUndo=false
    public var globalMode=AutoRestoreMode.defaultMode
    public var monitorChoice: AutoRestoreMode?
    public var keepAwakeMode=KeepAwakeMode.defaultMode
    public var pausedUntil: Date?
    public var now=Date()
    public var hotkeys=HotkeySettings.defaults
    public var optionHeld=false
    /// Latest notice macOS could not show (notifications off or not allowed). Kept in the menu so it is not lost.
    public var pendingNotice: String?
    public var pendingNoticeDetail: String?
    public init() {}
}

public enum StatusMenuModel {
    public static let arrangementPrefix="arrange.p."
    public static let quickArrangementPrefix="arrange.q."
    static func arrangementMenu(_ a: ArrangementMenu) -> MenuItemModel {
        let quickWhy=a.busy ?? a.quickBlock
        var children=a.quick.map { q in
            MenuItemModel(kind:.action,id:quickArrangementPrefix+q.edge.rawValue,title:ArrangementGeometry.quickName(edge:q.edge),enabled:quickWhy == nil,reason:quickWhy,checked:q.active)
        }
        if !children.isEmpty { children.append(.separator("arrange.sep.quick")) }
        if !a.entries.isEmpty { children.append(MenuItemModel(kind:.status,id:"arrange.saved",title:lk("自定义位置"),enabled:false)) }
        children+=a.entries.map { e in
            let why=a.busy ?? e.blocked
            return MenuItemModel(kind:.action,id:arrangementPrefix+e.id,title:e.name,enabled:why == nil,reason:why,hotkey:e.hotkey,checked:e.active)
        }
        if a.entries.isEmpty && a.quick.isEmpty { children.append(MenuItemModel(kind:.status,id:"arrange.none",title:lk("还没有这组屏幕的排列"),enabled:false)) }
        if a.otherCount>0 { children.append(MenuItemModel(kind:.status,id:"arrange.other",title:lk("另有 %@ 个排列属于别的屏幕组合", "\(a.otherCount)"),enabled:false)) }
        children.append(.separator("arrange.sep"))
        if let pb=a.portBinding {
            let portEnabled=a.busy == nil
            if pb.activeIsBound,let bound=pb.boundName {
                children.append(MenuItemModel(kind:.action,id:"arrange.port.unbind",title:lk("插在 %@ 时自动用「%@」", pb.portLabel, bound),enabled:portEnabled,reason:a.busy,checked:true))
            } else if let cur=pb.currentName {
                let sub=pb.boundName.map{ lk("当前已绑「%@」", $0) }
                children.append(MenuItemModel(kind:.action,id:"arrange.port.bind",title:lk("插在 %@ 时自动用「%@」", pb.portLabel, cur),symbol:"cable.connector",enabled:portEnabled,reason:a.busy ?? sub))
            } else if let bound=pb.boundName {
                children.append(MenuItemModel(kind:.action,id:"arrange.port.unbind",title:lk("插在 %@ 时自动用「%@」", pb.portLabel, bound),enabled:portEnabled,reason:a.busy,checked:true))
            }
        }
        let saveWhy=a.busy ?? a.saveBlock
        children.append(MenuItemModel(kind:.action,id:"arrange.save",title:lk("存当前位置（自定义）…"),symbol:"plus",enabled:saveWhy == nil,reason:saveWhy))
        children.append(MenuItemModel(kind:.action,id:"arrange.manage",title:lk("管理排列…")))
        return MenuItemModel(kind:.submenu,id:"arrangement",title:lk("显示器排列"),symbol:"display.2",children:children)
    }
    public static func statusLine(_ s: MenuState) -> String {
        guard let name=s.monitorName else { return lk("未连接外接屏") }
        guard let saved=s.savedAt,let count=s.windowCount else { return lk("%@ · 尚未保存", "\(name)") }
        return lk("%@ · %@ 个窗口 · %@", "\(name)", "\(count)", "\(RelativeTime.short(saved,now:s.now))")
    }
    static func blocker(_ s: MenuState,needsLayout: Bool) -> String? {
        if s.monitorName == nil { return lk("未连接外接屏") }
        if !s.trusted { return lk("需要辅助功能权限") }
        if needsLayout && s.savedAt == nil { return lk("尚未保存布局") }
        if s.busy { return lk("正在处理上一个操作") }
        return nil
    }
    public static func build(_ s: MenuState) -> [MenuItemModel] {
        var items=[MenuItemModel(kind:.status,id:"status",title:statusLine(s),symbol:s.monitorName == nil ? "display.trianglebadge.exclamationmark" : "display",enabled:false)]
        if let notice=s.pendingNotice {
            items.append(MenuItemModel(kind:.action,id:"notice",title:notice,symbol:"bell.badge",reason:NoticeRouting.menuSubtitle(s.pendingNoticeDetail)))
        }
        let saveBlock=blocker(s,needsLayout:false)
        items.append(MenuItemModel(kind:.action,id:"save",title:lk("保存当前布局"),symbol:"square.and.arrow.down",enabled:saveBlock == nil,reason:saveBlock,hotkey:s.hotkeys.shown(.save)))
        let restoreBlock=blocker(s,needsLayout:true)
        if s.optionHeld {
            items.append(MenuItemModel(kind:.action,id:"previewRestore",title:lk("预览后恢复…"),symbol:"eye",enabled:restoreBlock == nil,reason:restoreBlock))
        } else {
            items.append(MenuItemModel(kind:.action,id:"restore",title:lk("恢复布局"),symbol:"arrow.uturn.backward.circle",enabled:restoreBlock == nil,reason:restoreBlock,hotkey:s.hotkeys.shown(.restore)))
        }
        if s.canUndo {
            items.append(MenuItemModel(kind:.action,id:"undo",title:lk("撤销上次恢复"),symbol:"arrow.uturn.left",enabled:s.trusted && !s.busy,reason:s.trusted ? nil : lk("需要辅助功能权限"),hotkey:s.hotkeys.shown(.undo)))
        }
        if s.monitorName != nil,!s.layouts.isEmpty {
            let block=blocker(s,needsLayout:false)
            var children=s.layouts.enumerated().map { i,l in
                MenuItemModel(kind:.action,id:"layout.\(i)",title:l.name,enabled:block == nil,reason:block,checked:l.active)
            }
            children.append(.separator("layout.sep"))
            children.append(MenuItemModel(kind:.action,id:"open",title:lk("管理版式…")))
            items.append(MenuItemModel(kind:.submenu,id:"layouts",title:lk("切换版式"),symbol:"square.stack.3d.up",children:children))
        }
        if let a=s.arrangement { items.append(arrangementMenu(a)) }
        items.append(.separator("sep1"))
        var modes=AutoRestoreMode.allCases.map { mode in
            MenuItemModel(kind:.action,id:"mode.\(mode.rawValue)",title:mode.title,checked:s.globalMode == mode)
        }
        if let name=s.monitorName,let choice=s.monitorChoice {
            modes.append(.separator("mode.sep"))
            modes.append(MenuItemModel(kind:.status,id:"mode.override",title:lk("%@：%@（已记住）", "\(name)", "\(choice.title)"),enabled:false))
            modes.append(MenuItemModel(kind:.action,id:"mode.forget",title:lk("改回跟随上面的设置")))
        }
        items.append(MenuItemModel(kind:.submenu,id:"mode",title:lk("接上屏幕时"),symbol:"cable.connector.horizontal",children:modes))
        let keepAwakeItems=KeepAwakeMode.allCases.map { mode in
            MenuItemModel(kind:.action,id:"keepAwake.\(mode.rawValue)",title:mode.title,checked:s.keepAwakeMode == mode)
        }
        items.append(MenuItemModel(kind:.submenu,id:"keepAwake",title:s.keepAwakeMode.menuTitle,symbol:s.keepAwakeMode == .off ? "moon.zzz" : "bolt.shield.fill",children:keepAwakeItems))
        items.append(.separator("sep2"))
        items.append(MenuItemModel(kind:.action,id:"open",title:lk("打开 LayoutKeeper…"),symbol:"macwindow"))
        items.append(MenuItemModel(kind:.action,id:"checkUpdates",title:lk("检查更新…"),symbol:"arrow.down.circle"))
        items.append(s.optionHeld ? MenuItemModel(kind:.action,id:"diagnostics",title:lk("诊断…"),symbol:"stethoscope",menuKey:",")
                                  : MenuItemModel(kind:.action,id:"settings",title:lk("设置…"),symbol:"gearshape",menuKey:","))
        items.append(MenuItemModel(kind:.action,id:"quit",title:lk("退出 LayoutKeeper"),symbol:"power",menuKey:"q"))
        return items
    }
}
