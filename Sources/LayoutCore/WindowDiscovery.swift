// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// WindowServer fields for one window, read in a batch by the Mac adapter.
/// `nil` traits on a candidate means the batch query was unavailable; rules then fall back
/// to the public CGWindowList fields only and never hide a window because of the missing data.
public struct WindowServerTraits: Codable, Equatable, Sendable {
    public var parentID: UInt32
    public var attributes: UInt64
    public var tags: UInt64
    public init(parentID: UInt32, attributes: UInt64, tags: UInt64) { self.parentID=parentID; self.attributes=attributes; self.tags=tags }

    // Undocumented bit meanings. The document-window / ordered-in combination follows the
    // observations published by yabai (MIT, Copyright (c) 2019 Åsmund Vikane; see THIRD_PARTY_NOTICES.md)
    // and was re-checked on macOS 27.0 (26A428): Chrome's address-bar and bubble popups are
    // parentless level-0 windows but lack the document bit, closed-but-retained windows lack the
    // ordered-in bit. Re-verify on every major macOS release.
    public var looksLikeDocumentWindow: Bool { tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x8000_0000 != 0) }
    public var isOrderedIn: Bool { attributes & 0x2 != 0 || tags & (UInt64(1) << 58) != 0 }
    public var minimizedHint: Bool { tags & (UInt64(1) << 60) != 0 }
}

/// One layer/geometry/membership row from the public window list plus optional WindowServer traits.
public struct CGWindowCandidate: Equatable {
    public var windowID: UInt32
    public var ownerPID: Int32
    public var layer: Int
    public var bounds: Rect
    public var alpha: Double
    /// `nil` means the membership read failed; an empty array means the WindowServer reported none.
    public var spaceIDs: [UInt64]?
    public var traits: WindowServerTraits?
    public init(windowID: UInt32, ownerPID: Int32, layer: Int, bounds: Rect, alpha: Double, spaceIDs: [UInt64]?, traits: WindowServerTraits?) {
        self.windowID=windowID; self.ownerPID=ownerPID; self.layer=layer; self.bounds=bounds; self.alpha=alpha; self.spaceIDs=spaceIDs; self.traits=traits
    }
}

public enum CandidateExclusion: String, Codable, CaseIterable, Sendable {
    case nonzeroLayer, attachedToParent, undersized, transparent, notDocumentWindow, orderedOut, membershipUnreadable, noSpaceMembership
    public var label: String {
        switch self {
        case .nonzeroLayer: return "非普通层级"
        case .attachedToParent: return "附属于其他窗口"
        case .undersized: return "尺寸过小"
        case .transparent: return "完全透明"
        case .notDocumentWindow: return "弹出/辅助窗口"
        case .orderedOut: return "已关闭或未显示"
        case .membershipUnreadable: return "桌面归属读取失败"
        case .noSpaceMembership: return "不属于任何桌面"
        }
    }
}

/// Where an AX window element came from during a scan.
public enum AXWindowSource: String, Codable, Sendable {
    case windowsList, focusedWindow, mainWindow, remoteToken
}

public enum WindowCandidateRules {
    public static let minimumWidth=100.0
    public static let minimumHeight=50.0

    /// First rule that disqualifies the row as a likely user window, or nil for a candidate.
    public static func exclusion(_ c: CGWindowCandidate) -> CandidateExclusion? {
        if c.layer != 0 { return .nonzeroLayer }
        if let traits=c.traits, traits.parentID != 0 { return .attachedToParent }
        if !(c.bounds.width >= minimumWidth && c.bounds.height >= minimumHeight) { return .undersized }
        if !(c.alpha > 0) { return .transparent }
        if let traits=c.traits {
            if !traits.looksLikeDocumentWindow { return .notDocumentWindow }
            if !traits.isOrderedIn && !traits.minimizedHint { return .orderedOut }
        }
        guard let spaces=c.spaceIDs else { return .membershipUnreadable }
        if spaces.isEmpty { return .noSpaceMembership }
        return nil
    }

    /// Candidate windows of `pid` that the published AX attributes did not already provide.
    public static func wantedWindowIDs(pid: Int32, candidates: [CGWindowCandidate], resolved: Set<UInt32>) -> Set<UInt32> {
        Set(candidates.lazy.filter { $0.ownerPID==pid && exclusion($0)==nil }.map(\.windowID)).subtracting(resolved)
    }

    /// Keeps the first element seen for every window ID, preserving order. Items without an ID are counted, not kept.
    public static func uniqueByWindowID<T>(_ items: [(id: UInt32?, value: T)]) -> (unique: [(id: UInt32, value: T)], missingID: Int, duplicates: Int) {
        var seen=Set<UInt32>(), unique=[(id: UInt32, value: T)](), missing=0, duplicates=0
        for item in items {
            guard let id=item.id, id != 0 else { missing+=1; continue }
            if seen.insert(id).inserted { unique.append((id,item.value)) } else { duplicates+=1 }
        }
        return (unique,missing,duplicates)
    }
}

/// Visit order for remote element IDs: from `start` up to `cap`, then wrap to 0 ..< start.
/// Lets a later scan resume where a time-limited scan stopped without skipping low IDs.
public struct ElementIDSweep: Sequence, IteratorProtocol, Sendable {
    public let start: UInt64
    public let cap: UInt64
    private var visited: UInt64=0
    public init(start: UInt64, cap: UInt64) { self.cap=cap; self.start=cap==0 ? 0 : start % cap }
    public mutating func next() -> UInt64? {
        guard visited < cap else { return nil }
        let value=(start &+ visited) % cap
        visited+=1
        return value
    }
}

/// Runtime-only per-window trace. Contains window IDs, so it is shown in diagnostics and
/// must never be written into a layout record.
public struct CaptureTraceEntry: Codable, Equatable {
    public var bundleID: String
    public var windowID: UInt32
    public var width: Int
    public var height: Int
    /// 1-based ordinary desktop slot on the selected display, when the window belongs to exactly one.
    public var spaceSlot: Int?
    /// selectedDisplay / otherDisplay / selectedNonordinary / multipleSpaces / unknownSpace / none
    public var placement: String
    public var exclusion: CandidateExclusion?
    public var axSource: AXWindowSource?
    /// captured, a CaptureReason raw value, notInAX, remoteTokenUnresolved, remoteTokenSkipped, notCandidate
    public var outcome: String
    public init(bundleID: String, windowID: UInt32, width: Int, height: Int, spaceSlot: Int?, placement: String, exclusion: CandidateExclusion?, axSource: AXWindowSource?, outcome: String) {
        self.bundleID=bundleID; self.windowID=windowID; self.width=width; self.height=height; self.spaceSlot=spaceSlot; self.placement=placement; self.exclusion=exclusion; self.axSource=axSource; self.outcome=outcome
    }
    public var line: String {
        let slot=spaceSlot.map{"桌面\($0)"} ?? placement
        let source=axSource?.rawValue ?? "noAX"
        let reason=exclusion.map{"；排除：\($0.label)"} ?? ""
        return "\(bundleID) #\(windowID) \(width)×\(height) \(slot) \(source) → \(outcome)\(reason)"
    }
}
