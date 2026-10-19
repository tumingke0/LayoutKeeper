// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import Carbon
import LayoutCore

/// Builds the real NSMenu from `StatusMenuModel` (the snapshot renderer draws the same model).
enum StatusMenuBuilder {
    static func make(_ items: [MenuItemModel],target: AnyObject,action: Selector) -> [NSMenuItem] {
        items.map { model in
            switch model.kind {
            case .separator: return NSMenuItem.separator()
            case .status:
                let item=NSMenuItem(title:model.title,action:nil,keyEquivalent:"")
                item.isEnabled=false
                if let symbol=model.symbol { item.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil) }
                return item
            case .action, .submenu:
                let item=NSMenuItem(title:model.title,action:model.kind == .action ? action : nil,keyEquivalent:"")
                item.target=target; item.representedObject=model.id
                item.isEnabled=model.enabled
                item.state=model.checked ? .on : .off
                if let symbol=model.symbol { item.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil) }
                if let reason=model.reason {
                    if #available(macOS 14.4, *) { item.subtitle=reason } else { item.title=lk("%@（%@）", "\(model.title)", "\(reason)") }
                    item.toolTip=reason
                }
                if let key=model.hotkey,let equivalent=KeyCodes.keyEquivalent(key.keyCode) {
                    item.keyEquivalent=equivalent
                    var mask=NSEvent.ModifierFlags()
                    if key.modifiers.contains(.command) { mask.insert(.command) }
                    if key.modifiers.contains(.option) { mask.insert(.option) }
                    if key.modifiers.contains(.control) { mask.insert(.control) }
                    if key.modifiers.contains(.shift) { mask.insert(.shift) }
                    item.keyEquivalentModifierMask=mask
                } else if let key=model.menuKey {
                    item.keyEquivalent=key; item.keyEquivalentModifierMask=[.command]
                }
                if model.kind == .submenu {
                    let sub=NSMenu(); sub.autoenablesItems=false
                    make(model.children,target:target,action:action).forEach(sub.addItem)
                    item.submenu=sub
                }
                return item
            }
        }
    }
}

/// System-wide shortcuts via Carbon RegisterEventHotKey (no Accessibility or Input Monitoring needed).
/// IDs below `presetBase` are the fixed actions; from `presetBase` on, the display arrangement presets in order.
final class GlobalHotkeys {
    private var refs: [HotkeyAction:EventHotKeyRef]=[:]
    private var presetRefs: [String:EventHotKeyRef]=[:]
    private var presetIDs: [String]=[]
    private var handler: EventHandlerRef?
    var onPress: (HotkeyAction) -> Void={ _ in }
    var onPresetPress: (String) -> Void={ _ in }
    private static let signature: OSType=0x4C4B4859 // "LKHY"
    private static let presetBase: UInt32=1000
    func install() {
        guard handler == nil else { return }
        var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let me=Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,userData in
            guard let event,let userData else { return OSStatus(eventNotHandledErr) }
            var id=EventHotKeyID()
            let status=GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            guard status == noErr,id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            let hotkeys=Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
            if Int(id.id)<HotkeyAction.allCases.count {
                let action=HotkeyAction.allCases[Int(id.id)]
                DispatchQueue.main.async { hotkeys.onPress(action) }
                return noErr
            }
            guard id.id>=GlobalHotkeys.presetBase,Int(id.id-GlobalHotkeys.presetBase)<hotkeys.presetIDs.count else { return OSStatus(eventNotHandledErr) }
            let preset=hotkeys.presetIDs[Int(id.id-GlobalHotkeys.presetBase)]
            DispatchQueue.main.async { hotkeys.onPresetPress(preset) }
            return noErr
        },1,&spec,me,&handler)
    }
    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        for ref in presetRefs.values { UnregisterEventHotKey(ref) }
        refs=[:]; presetRefs=[:]
    }
    func apply(_ settings: HotkeySettings,presets: [ArrangementPreset]) -> (actions: [HotkeyAction:HotkeyStatus],presets: [String:HotkeyStatus]) {
        install(); unregisterAll()
        let actions=HotkeyRegistrar.register(settings) { action,key in
            var ref: EventHotKeyRef?
            let index=UInt32(HotkeyAction.allCases.firstIndex(of:action) ?? 0)
            let status=RegisterEventHotKey(key.keyCode,key.modifiers.carbonFlags,EventHotKeyID(signature:GlobalHotkeys.signature,id:index),GetApplicationEventTarget(),0,&ref)
            guard status == noErr,let ref else { return false }
            refs[action]=ref; return true
        }
        var taken=[Hotkey:String]()
        for (action,status) in actions where status == .active { if let key=settings.keys[action] { taken[key]=action.title } }
        presetIDs=presets.map(\.id)
        let result=HotkeyRegistrar.registerPresets(presets.map{ (id:$0.id,title:$0.name,key:$0.hotkey) },enabled:settings.enabled,taken:taken) { id,key in
            guard let index=presetIDs.firstIndex(of:id) else { return false }
            var ref: EventHotKeyRef?
            let status=RegisterEventHotKey(key.keyCode,key.modifiers.carbonFlags,EventHotKeyID(signature:GlobalHotkeys.signature,id:GlobalHotkeys.presetBase+UInt32(index)),GetApplicationEventTarget(),0,&ref)
            guard status == noErr,let ref else { return false }
            presetRefs[id]=ref; return true
        }
        return (actions,result)
    }
}
