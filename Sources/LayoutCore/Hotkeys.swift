// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public struct HotkeyModifiers: OptionSet, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue=rawValue }
    public static let control=HotkeyModifiers(rawValue:1)
    public static let option=HotkeyModifiers(rawValue:2)
    public static let shift=HotkeyModifiers(rawValue:4)
    public static let command=HotkeyModifiers(rawValue:8)
    /// Carbon `RegisterEventHotKey` modifier bits (cmdKey, shiftKey, optionKey, controlKey).
    public var carbonFlags: UInt32 {
        var f: UInt32=0
        if contains(.command) { f |= 0x0100 }
        if contains(.shift) { f |= 0x0200 }
        if contains(.option) { f |= 0x0800 }
        if contains(.control) { f |= 0x1000 }
        return f
    }
    /// Apple order: ⌃ ⌥ ⇧ ⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "")+(contains(.option) ? "⌥" : "")+(contains(.shift) ? "⇧" : "")+(contains(.command) ? "⌘" : "")
    }
}

/// Virtual key codes (kVK_*) of the ANSI layout that we can display and use as menu key equivalents.
public enum KeyCodes {
    static let table: [UInt32:String]=[
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
        37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`",
        122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",
        123:"←",124:"→",125:"↓",126:"↑",49:"Space",36:"↩"
    ]
    public static func name(_ code: UInt32) -> String? { table[code] }
    /// Single-character menu key equivalent (lowercase), nil for keys a menu can't show this way.
    public static func keyEquivalent(_ code: UInt32) -> String? {
        guard let n=table[code],n.count==1,!["←","→","↓","↑","↩"].contains(n) else { return nil }
        return n.lowercased()
    }
}

public struct Hotkey: Codable, Hashable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers
    public init(keyCode: UInt32, modifiers: HotkeyModifiers) { self.keyCode=keyCode; self.modifiers=modifiers }
    public var display: String { modifiers.symbols+(KeyCodes.name(keyCode) ?? "#\(keyCode)") }
    public static let hyper: HotkeyModifiers=[.control,.option,.command]
}

public enum HotkeyAction: String, CaseIterable, Codable {
    case save, restore, undo
    public var title: String {
        switch self { case .save: return lk("保存当前布局"); case .restore: return lk("恢复布局"); case .undo: return lk("撤销上次恢复") }
    }
}

public struct HotkeySettings: Codable, Equatable {
    public var enabled=true
    public var keys: [HotkeyAction:Hotkey]
    public init(enabled: Bool = true, keys: [HotkeyAction:Hotkey]) { self.enabled=enabled; self.keys=keys }
    /// ⌃⌥⌘S / ⌃⌥⌘R / ⌃⌥⌘Z.
    public static let defaults=HotkeySettings(keys:[.save:Hotkey(keyCode:1,modifiers:Hotkey.hyper),.restore:Hotkey(keyCode:15,modifiers:Hotkey.hyper),.undo:Hotkey(keyCode:6,modifiers:Hotkey.hyper)])
    /// The shortcut to show in menus (nil when hotkeys are off or the key is cleared).
    public func shown(_ action: HotkeyAction) -> Hotkey? { enabled ? keys[action] : nil }
}

public enum HotkeyStatus: Hashable {
    case active, off, unset, conflict(String), invalid(String)
    public var message: String? {
        switch self {
        case .conflict(let m), .invalid(let m): return m
        default: return nil
        }
    }
}

/// Registration policy. The actual system call is injected; a failed registration is reported as a conflict
/// (another app or the system already owns that combination).
public enum HotkeyRegistrar {
    public static func validate(_ key: Hotkey) -> String? {
        guard !key.modifiers.intersection([.command,.control,.option]).isEmpty else { return lk("需要包含 ⌘、⌃ 或 ⌥ 中的至少一个") }
        guard KeyCodes.name(key.keyCode) != nil else { return lk("不支持这个按键") }
        return nil
    }
    public static func register(_ settings: HotkeySettings,attempt: (HotkeyAction,Hotkey) -> Bool) -> [HotkeyAction:HotkeyStatus] {
        var result=[HotkeyAction:HotkeyStatus]()
        var taken=[Hotkey:HotkeyAction]()
        for action in HotkeyAction.allCases {
            guard settings.enabled else { result[action] = .off; continue }
            guard let key=settings.keys[action] else { result[action] = .unset; continue }
            if let why=validate(key) { result[action] = .invalid(why); continue }
            if let owner=taken[key] { result[action] = .conflict(lk("与「%@」重复", "\(owner.title)")); continue }
            if attempt(action,key) { result[action] = .active; taken[key]=action }
            else { result[action] = .conflict(lk("%@ 注册失败：可能已被系统或其他应用占用，请换一个", "\(key.display)")) }
        }
        return result
    }
}
