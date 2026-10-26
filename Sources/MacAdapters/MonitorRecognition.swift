// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore

public struct ConnectedMonitor {
    public var identity: MonitorIdentity
    public var runtimeDisplayToken: String
    public var portID: String?
    public var portLabel: String?
    public init(identity: MonitorIdentity, runtimeDisplayToken: String, portID: String? = nil, portLabel: String? = nil) {
        self.identity=identity; self.runtimeDisplayToken=runtimeDisplayToken; self.portID=portID; self.portLabel=portLabel
    }
}
public enum MonitorRecognition {
    /// 布局模式; set by the app from preferences. In shared mode a single external monitor is reported with the shared identity.
    nonisolated(unsafe) public static var layoutMode: LayoutMode = .perMonitor
    public static func externalMonitors() -> [ConnectedMonitor] {
        var list=physicalExternalMonitors()
        if list.count==1,let shared=SharedLayout.effective(list.map(\.identity),mode:layoutMode).first { list[0].identity=shared }
        return list
    }
    public static func physicalExternalMonitors() -> [ConnectedMonitor] {
        let ports=DisplayPortReader.activePorts()
        return NSScreen.screens.compactMap { screen in
            guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id=number.uint32Value
            guard CGDisplayIsBuiltin(id)==0, let uuid=CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let string=CFUUIDCreateString(nil,uuid) else { return nil }
            let vendor=CGDisplayVendorNumber(id), model=CGDisplayModelNumber(id), rawSerial=CGDisplaySerialNumber(id)
            let port=DisplayPortMatcher.match(model:model,numericSerial:rawSerial,ports:ports)
            let serial=EDIDParser.effectiveSerial(numericSerial:rawSerial,edid:port?.edid)
            return ConnectedMonitor(identity:MonitorIdentity(vendor:vendor,model:model,serial:serial,name:screen.localizedName),
                                    runtimeDisplayToken:string as String,portID:port?.portID,portLabel:port?.label)
        }
    }
}
