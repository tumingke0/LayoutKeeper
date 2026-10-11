// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public enum FrameWriteStep: String, Codable { case size, position }

/// Order of AX writes for one frame change. Writing the position of a large window first can be
/// clamped by the screen edge, and growing a window before moving it can be clamped the other way.
public enum FrameWritePlanner {
    /// Shrinking in any dimension: size, then position. Otherwise: position, then size.
    public static func order(current: Rect, target: Rect) -> [FrameWriteStep] {
        let shrinks=target.width < current.width-0.5 || target.height < current.height-0.5
        return shrinks ? [.size,.position] : [.position,.size]
    }
    /// One retry in the opposite order, ending with a size write so the final size is not clamped by the old origin.
    public static func retry(after first: [FrameWriteStep]) -> [FrameWriteStep] {
        let reversed=Array(first.reversed())
        return reversed.last == .size ? reversed : reversed+[.size]
    }
}

/// Which parts of an attempted frame write took effect, judged from a readback.
public struct FrameWriteOutcome: Codable, Equatable {
    public var positionApplied: Bool
    public var sizeApplied: Bool
    public init(positionApplied: Bool, sizeApplied: Bool) { self.positionApplied=positionApplied; self.sizeApplied=sizeApplied }
    public init(observed: Rect, target: Rect, tolerance: Double = 3) {
        positionApplied=abs(observed.x-target.x)<=tolerance && abs(observed.y-target.y)<=tolerance
        sizeApplied=abs(observed.width-target.width)<=tolerance && abs(observed.height-target.height)<=tolerance
    }
    public var complete: Bool { positionApplied && sizeApplied }
}
