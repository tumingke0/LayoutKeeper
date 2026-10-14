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

public struct MenuState {
    public var layouts: [MenuLayout]=[]
    public var monitorName: String?
    public var windowCount: Int?
    public var savedAt: Date?
    public var trusted=true
    public var busy=false
    public var canUndo=false
    public var globalMode=AutoRestoreMode.defaultMode
    public var monitorChoice: AutoRestoreMode?
    public var pausedUntil: Date?
    public var now=Date()
    public var hotkeys=HotkeySettings.defaults
    public var optionHeld=false
    public init() {}
}

public enum StatusMenuModel {
    public static func statusLine(_ s: MenuState) -> String {
        guard let name=s.monitorName else { return "未连接外接屏" }
        guard let saved=s.savedAt,let count=s.windowCount else { return "\(name) · 尚未保存" }
        return "\(name) · \(count) 个窗口 · \(RelativeTime.short(saved,now:s.now))"
    }
    static func blocker(_ s: MenuState,needsLayout: Bool) -> String? {
        if s.monitorName == nil { return "未连接外接屏" }
        if !s.trusted { return "需要辅助功能权限" }
        if needsLayout && s.savedAt == nil { return "尚未保存布局" }
        if s.busy { return "正在处理上一个操作" }
        return nil
    }
    public static func build(_ s: MenuState) -> [MenuItemModel] {
        var items=[MenuItemModel(kind:.status,id:"status",title:statusLine(s),symbol:s.monitorName == nil ? "display.trianglebadge.exclamationmark" : "display",enabled:false)]
        let saveBlock=blocker(s,needsLayout:false)
        items.append(MenuItemModel(kind:.action,id:"save",title:"保存当前布局",symbol:"square.and.arrow.down",enabled:saveBlock == nil,reason:saveBlock,hotkey:s.hotkeys.shown(.save)))
        let restoreBlock=blocker(s,needsLayout:true)
        if s.optionHeld {
            items.append(MenuItemModel(kind:.action,id:"previewRestore",title:"预览后恢复…",symbol:"eye",enabled:restoreBlock == nil,reason:restoreBlock))
        } else {
            items.append(MenuItemModel(kind:.action,id:"restore",title:"恢复布局",symbol:"arrow.uturn.backward.circle",enabled:restoreBlock == nil,reason:restoreBlock,hotkey:s.hotkeys.shown(.restore)))
        }
        if s.canUndo {
            items.append(MenuItemModel(kind:.action,id:"undo",title:"撤销上次恢复",symbol:"arrow.uturn.left",enabled:s.trusted && !s.busy,reason:s.trusted ? nil : "需要辅助功能权限",hotkey:s.hotkeys.shown(.undo)))
        }
        if s.monitorName != nil,!s.layouts.isEmpty {
            let block=blocker(s,needsLayout:false)
            var children=s.layouts.enumerated().map { i,l in
                MenuItemModel(kind:.action,id:"layout.\(i)",title:l.name,enabled:block == nil,reason:block,checked:l.active)
            }
            children.append(.separator("layout.sep"))
            children.append(MenuItemModel(kind:.action,id:"open",title:"管理版式…"))
            items.append(MenuItemModel(kind:.submenu,id:"layouts",title:"切换版式",symbol:"square.stack.3d.up",children:children))
        }
        items.append(.separator("sep1"))
        var modes=AutoRestoreMode.allCases.map { mode in
            MenuItemModel(kind:.action,id:"mode.\(mode.rawValue)",title:mode.title,checked:s.globalMode == mode)
        }
        if let name=s.monitorName,let choice=s.monitorChoice {
            modes.append(.separator("mode.sep"))
            modes.append(MenuItemModel(kind:.status,id:"mode.override",title:"\(name)：\(choice.title)（已记住）",enabled:false))
            modes.append(MenuItemModel(kind:.action,id:"mode.forget",title:"改回跟随上面的设置"))
        }
        items.append(MenuItemModel(kind:.submenu,id:"mode",title:"接上屏幕时",symbol:"cable.connector.horizontal",children:modes))
        items.append(.separator("sep2"))
        items.append(MenuItemModel(kind:.action,id:"open",title:"打开 LayoutKeeper…",symbol:"macwindow"))
        items.append(MenuItemModel(kind:.action,id:"checkUpdates",title:"检查更新…",symbol:"arrow.down.circle"))
        items.append(s.optionHeld ? MenuItemModel(kind:.action,id:"diagnostics",title:"诊断…",symbol:"stethoscope",menuKey:",")
                                  : MenuItemModel(kind:.action,id:"settings",title:"设置…",symbol:"gearshape",menuKey:","))
        items.append(MenuItemModel(kind:.action,id:"quit",title:"退出 LayoutKeeper",symbol:"power",menuKey:"q"))
        return items
    }
}
