// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// 布局模式 (0.6.2). `perMonitor` keeps one layout per external monitor (the original behavior);
/// `sharedExternal` uses one layout for whichever single external monitor is attached (home, office, …).
public enum LayoutMode: String, CaseIterable, Codable {
    case perMonitor, sharedExternal
    public static let defaultMode=LayoutMode.perMonitor
    public static let preferenceKey="layoutMode"
    public var title: String { self == .perMonitor ? lk("每块屏单独记") : lk("所有外接屏共用一套") }
}

extension MonitorIdentity {
    /// Virtual identity of the shared layout. Stored as `screens/shared-external.json` with the usual history and 版式.
    public static let sharedExternal=MonitorIdentity(vendor:0x4C4B,model:0x5348,serial:1,name:lk("共用外接屏"))
    public var isSharedExternal: Bool { vendor==0x4C4B && model==0x5348 && serial==1 }
    public static let sharedExternalKey="shared-external"
}

public enum SharedLayout {
    /// The identities the app works with. Shared mode applies only with exactly one external monitor;
    /// with two or more it falls back to per-monitor records.
    public static func effective(_ identities: [MonitorIdentity],mode: LayoutMode) -> [MonitorIdentity] {
        mode == .sharedExternal && identities.count==1 ? [.sharedExternal] : identities
    }
    /// True when shared mode was chosen but can't apply because several external monitors are attached.
    public static func fellBack(externalCount: Int,mode: LayoutMode) -> Bool { mode == .sharedExternal && externalCount>1 }

    /// Maps a saved 1-based Space ordinal onto the Spaces that exist now. With too few Spaces the window goes to the last one.
    public static func targetSlot(saved: Int,available: Int) -> Int? {
        guard saved>=1,available>=1 else { return nil }
        return min(saved,available)
    }
    public static func missingDesktops(needed: Int,available: Int) -> Int { max(0,needed-available) }

    /// First switch to shared mode: copies the connected screen's current layout (else the most recently saved one) as the
    /// shared layout. Per-monitor files are never changed. Returns the source key, or nil when nothing was seeded.
    @discardableResult public static func seed(library: ScreenLibrary,preferredKey: String?) throws -> String? {
        let fm=FileManager.default
        let target=library.currentURL(MonitorIdentity.sharedExternalKey)
        guard !fm.fileExists(atPath:target.path) else { return nil }
        let candidates=library.screens(connectedKey:preferredKey) { $0.name }.filter { !$0.monitor.isSharedExternal }
        guard let source=candidates.first(where:{ $0.key==preferredKey }) ?? candidates.first else { return nil }
        var record=try MonitorLayoutStore.load(from:library.currentURL(source.key))
        record.monitor = .sharedExternal
        try record.validate()
        try fm.createDirectory(at:library.root,withIntermediateDirectories:true)
        try MonitorLayoutStore.save(record,to:target)
        return source.key
    }
}

/// The ordinary Spaces per display, recorded periodically so an unplug can be compared with the state just before it.
public struct SpaceCensus: Equatable, Codable {
    public var external: [UInt64]
    public var builtIn: [UInt64]
    public var externalCount: Int
    public init(external: [UInt64],builtIn: [UInt64],externalCount: Int) { self.external=external; self.builtIn=builtIn; self.externalCount=externalCount }
    public static func take(_ displays: [Display],_ spaces: [Space],externalCount: Int) -> SpaceCensus {
        let ext=Set(displays.filter{ $0.role == .external }.map(\.token)),bi=Set(displays.filter{ $0.role == .builtIn }.map(\.token))
        let ordinary=spaces.filter{ $0.kind == .ordinary }
        return SpaceCensus(external:ordinary.filter{ ext.contains($0.displayToken) }.map(\.id),builtIn:ordinary.filter{ bi.contains($0.displayToken) }.map(\.id),externalCount:externalCount)
    }
    /// How many Spaces macOS moved onto the built-in display when the external monitor went away (no deletion is done).
    public static func migratedToBuiltIn(before: SpaceCensus,after: SpaceCensus) -> Int {
        guard before.externalCount>0,after.externalCount==0 else { return 0 }
        let moved=after.builtIn.filter{ before.external.contains($0) }.count
        return moved>0 ? moved : max(0,after.builtIn.count-before.builtIn.count)
    }
}
