// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import CoreGraphics
import LayoutCore

/// CoreGraphics reads and writes for display arrangement presets (public API only:
/// CGBeginDisplayConfiguration / CGConfigureDisplayOrigin / CGCompleteDisplayConfiguration).
public enum DisplayArrangementIO {
    /// Every online display that is drawing or part of a mirror set, in CoreGraphics global space (points).
    public static func live() -> [LiveDisplay] {
        var count: UInt32=0
        guard CGGetOnlineDisplayList(0,nil,&count) == .success,count>0 else { return [] }
        var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
        guard CGGetOnlineDisplayList(count,&ids,&count) == .success else { return [] }
        var names=[CGDirectDisplayID:String]()
        for screen in NSScreen.screens { if let n=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { names[n.uint32Value]=screen.localizedName } }
        return ids.prefix(Int(count)).compactMap { id in
            let mirrored=CGDisplayIsInMirrorSet(id) != 0
            guard CGDisplayIsActive(id) != 0 || mirrored else { return nil }
            guard let uuid=CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),let text=CFUUIDCreateString(nil,uuid) as String? else { return nil }
            let b=CGDisplayBounds(id), builtIn=CGDisplayIsBuiltin(id) != 0
            return LiveDisplay(id:id,key:LiveDisplay.key(builtIn:builtIn,vendor:CGDisplayVendorNumber(id),model:CGDisplayModelNumber(id),serial:CGDisplaySerialNumber(id)),
                               uuid:text.uppercased(),name:names[id] ?? (builtIn ? "Built-in" : "Display \(id)"),builtIn:builtIn,isMain:CGDisplayIsMain(id) != 0,
                               x:Int(b.origin.x.rounded()),y:Int(b.origin.y.rounded()),width:Int(b.width.rounded()),height:Int(b.height.rounded()),
                               mirrored:mirrored,asleep:CGDisplayIsAsleep(id) != 0)
        }
    }

    public enum Scope: String, Sendable {
        /// Undone by macOS when LayoutKeeper quits or crashes: the preview while the user decides.
        case appOnly
        /// Until logout; only a fallback preview if the app-only scope is refused.
        case session
        /// Written where System Settings keeps the arrangement.
        case permanent
        var option: CGConfigureOption {
            switch self { case .appOnly: return .forAppOnly; case .session: return .forSession; case .permanent: return .permanently }
        }
    }

    public struct Outcome: Sendable {
        public var error: CGError?
        public var attempts: Int
        /// Displays whose origin after the commit is not what was asked (WindowServer adjusted them).
        public var adjusted: [String]
        public var ok: Bool { error == nil }
    }

    /// One transaction with an origin for every target. Transient refusals (an app in full screen, a mode change in
    /// flight) are retried a few times. Display IDs are re-checked right before the transaction.
    public static func apply(_ targets: [ArrangementTarget],scope: Scope,attempts: Int = 3) -> Outcome {
        var last: CGError = .failure
        for attempt in 1...max(1,attempts) {
            let e=transaction(targets,option:scope.option)
            if e == .success {
                let now=Dictionary(live().map{ ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
                let adjusted=targets.filter{ t in now[t.id].map{ $0.x != t.x || $0.y != t.y } ?? true }.map(\.key)
                return Outcome(error:nil,attempts:attempt,adjusted:adjusted)
            }
            last=e
            guard e == .failure || e == .cannotComplete,attempt<attempts else { return Outcome(error:e,attempts:attempt,adjusted:[]) }
            usleep(useconds_t(250_000*attempt))
        }
        return Outcome(error:last,attempts:attempts,adjusted:[])
    }

    private static func transaction(_ targets: [ArrangementTarget],option: CGConfigureOption) -> CGError {
        let online=Set(live().map(\.id))
        guard targets.allSatisfy({ online.contains($0.id) }) else { return .illegalArgument }
        var ref: CGDisplayConfigRef?
        let begin=CGBeginDisplayConfiguration(&ref)
        guard begin == .success,let config=ref else { return begin }
        for t in targets {
            let e=CGConfigureDisplayOrigin(config,t.id,Int32(t.x),Int32(t.y))
            // A configuration that is not completed must be cancelled, or WindowServer keeps the transaction.
            if e != .success { CGCancelDisplayConfiguration(config); return e }
        }
        return CGCompleteDisplayConfiguration(config,option)
    }

    /// Last resort when a revert fails: back to the arrangement stored for this user (what System Settings shows).
    public static func restorePermanent() { CGRestorePermanentDisplayConfiguration() }
}
