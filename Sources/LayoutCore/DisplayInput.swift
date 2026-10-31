// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// 0.6.15: one entry of a monitor's 「切换输入源」 list. `value` is the byte written to VCP 0x60 (or 0xF4 on sub-address
/// 0x50 when `lgAlt`). Names are labels only: the same value can mean a different port on another monitor model.
public struct InputSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var value: UInt8
    public var lgAlt: Bool
    public var visible: Bool
    public init(id: String,name: String,value: UInt8,lgAlt: Bool=false,visible: Bool=true) {
        self.id=id; self.name=name; self.value=value; self.lgAlt=lgAlt; self.visible=visible
    }
    /// (VCP code, sub-address) the value is written with.
    public var command: (code: UInt8,subAddress: UInt8) {
        lgAlt ? (DDCPacket.inputSelectAlt,DDCPacket.altSubAddress) : (DDCPacket.inputSelect,DDCPacket.defaultSubAddress)
    }
}

public enum InputSourceCatalog {
    /// MCCS values for DisplayPort 1/2 and HDMI 1/2; 0x1B is the value ddcctl and m1ddc use for USB-C.
    public static let defaults: [InputSource]=[
        InputSource(id:"dp1",name:"DisplayPort 1",value:0x0F),
        InputSource(id:"dp2",name:"DisplayPort 2",value:0x10),
        InputSource(id:"hdmi1",name:"HDMI 1",value:0x11),
        InputSource(id:"hdmi2",name:"HDMI 2",value:0x12),
        InputSource(id:"usbc",name:"USB-C",value:0x1B),
    ]
}

public enum InputValueParser {
    /// "17" or "0x11" → 17. Valid range 1...255 (0 is not an input in MCCS).
    public static func parse(_ text: String) -> UInt8? {
        let t=text.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        let n: Int?
        if t.hasPrefix("0x") {
            let hex=t.dropFirst(2)
            n=hex.isEmpty || hex.count>4 ? nil : Int(hex,radix:16)
        } else {
            n=t.count>5 ? nil : Int(t,radix:10)
        }
        guard let n,(1...255).contains(n) else { return nil }
        return UInt8(n)
    }
    /// 17 → "0x11"
    public static func format(_ v: UInt8) -> String { String(format:"0x%02X",v) }
}

/// Per-display input lists, stored as one JSON blob.
public enum InputSourceStore {
    public static func decode(_ data: Data?) -> [String:[InputSource]] {
        guard let data,let map=try? JSONDecoder().decode([String:[InputSource]].self,from:data) else { return [:] }
        return map
    }
    public static func encode(_ map: [String:[InputSource]]) -> Data? { try? JSONEncoder().encode(map) }
    public static func sources(_ map: [String:[InputSource]],key: String) -> [InputSource] { map[key] ?? InputSourceCatalog.defaults }
    /// Saving the default list removes the entry, so later changes to the defaults reach this display.
    public static func setting(_ map: [String:[InputSource]],key: String,sources: [InputSource]) -> [String:[InputSource]] {
        var m=map
        m[key]=sources == InputSourceCatalog.defaults ? nil : sources
        return m
    }
}

/// What clicking an input does. Switching away can leave the Mac without a way back (many monitors ignore DDC from an
/// inactive input), so the first switch per display is confirmed, and switching the Mac's only lit screen always is.
public enum InputSwitchDecision: Equatable {
    case blocked(String)
    /// The Mac's only active screen: always ask, no "don't ask again".
    case confirmStrong
    /// First switch on this display: ask, with "don't ask again".
    case confirmOnce
    case go
}

public enum InputSwitchPolicy {
    public static func decide(isBuiltIn: Bool,ddcAvailable: Bool,mappingCertain: Bool,isOnlyActiveScreen: Bool,confirmedBefore: Bool) -> InputSwitchDecision {
        if isBuiltIn { return .blocked(lk("内建屏幕没有输入源")) }
        if !ddcAvailable { return .blocked(lk("这台显示器没有可用的 DDC")) }
        if !mappingCertain { return .blocked(lk("无法确认这台显示器对应的 DDC 通道")) }
        if isOnlyActiveScreen { return .confirmStrong }
        return confirmedBefore ? .go : .confirmOnce
    }
}

/// The 「切换输入源」 submenu. nil hides it (feature off, no DDC monitor).
public struct InputMenu: Equatable {
    public struct Display: Equatable {
        public var id: UInt32
        public var name: String
        /// Why this display can't be switched (nil = it can).
        public var blocked: String?
        public var sources: [InputSource]
        public init(id: UInt32,name: String,blocked: String?,sources: [InputSource]) { self.id=id; self.name=name; self.blocked=blocked; self.sources=sources }
    }
    public var displays: [Display]
    public init(displays: [Display]) { self.displays=displays }

    public static let prefix="input."
    public static let editID="input.edit"
    public static func itemID(display: UInt32,source: String) -> String { "\(prefix)\(display).\(source)" }
    /// "input.<display>.<source>" → (display, source). Source ids never contain dots.
    public static func parse(_ id: String) -> (display: UInt32,source: String)? {
        guard id.hasPrefix(prefix),id != editID else { return nil }
        let parts=id.dropFirst(prefix.count).split(separator:".",maxSplits:1,omittingEmptySubsequences:false)
        guard parts.count == 2,let d=UInt32(parts[0]),!parts[1].isEmpty else { return nil }
        return (d,String(parts[1]))
    }
    /// Makes an id usable in `itemID`.
    public static func sanitizedSourceID(_ s: String) -> String { s.replacingOccurrences(of:".",with:"-") }

    func items(_ d: Display) -> [MenuItemModel] {
        let visible=d.sources.filter(\.visible)
        var out: [MenuItemModel]=[]
        if let why=d.blocked { out.append(MenuItemModel(kind:.status,id:"input.blocked.\(d.id)",title:why,enabled:false)) }
        if visible.isEmpty { out.append(MenuItemModel(kind:.status,id:"input.none.\(d.id)",title:lk("没有显示在菜单中的输入源"),enabled:false)) }
        out+=visible.map { s in
            MenuItemModel(kind:.action,id:Self.itemID(display:d.id,source:s.id),title:s.name,enabled:d.blocked == nil)
        }
        return out
    }
    public var menuItem: MenuItemModel? {
        guard !displays.isEmpty else { return nil }
        var children: [MenuItemModel]
        if displays.count == 1 {
            children=items(displays[0])
        } else {
            children=displays.map { d in
                MenuItemModel(kind:.submenu,id:"input.display.\(d.id)",title:d.name,reason:d.blocked,children:items(d))
            }
        }
        children.append(.separator("input.sep"))
        children.append(MenuItemModel(kind:.action,id:Self.editID,title:lk("编辑输入源…")))
        return MenuItemModel(kind:.submenu,id:"input",title:lk("切换输入源"),symbol:"rectangle.connected.to.line.below",children:children)
    }
}
