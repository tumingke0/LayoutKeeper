// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore

public struct ConnectedMonitor {
    public var identity: MonitorIdentity
    public var runtimeDisplayToken: String
    public init(identity: MonitorIdentity, runtimeDisplayToken: String) { self.identity=identity; self.runtimeDisplayToken=runtimeDisplayToken }
}
public enum MonitorRecognition {
    public static func externalMonitors() -> [ConnectedMonitor] {
        NSScreen.screens.compactMap { screen in
            guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id=number.uint32Value
            guard CGDisplayIsBuiltin(id)==0, let uuid=CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let string=CFUUIDCreateString(nil,uuid) else { return nil }
            return ConnectedMonitor(identity:MonitorIdentity(vendor:CGDisplayVendorNumber(id),model:CGDisplayModelNumber(id),serial:CGDisplaySerialNumber(id),name:screen.localizedName),runtimeDisplayToken:string as String)
        }
    }
}
