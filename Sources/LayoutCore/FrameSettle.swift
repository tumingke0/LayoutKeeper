// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// After a monitor reconnects, macOS keeps moving windows for a moment. Restoring too early fights the system,
/// so we poll the frames of the saved apps' windows and plan only once they stop changing.
public struct FrameSettle {
    public enum Decision: Equatable { case waiting, settled, timedOut }
    public let quiet: TimeInterval
    public let maxWait: TimeInterval
    public let tolerance: Double
    public private(set) var startedAt: Date?
    public private(set) var lastChange: Date?
    private var last: [String:Rect]?
    public init(quiet: TimeInterval = 1, maxWait: TimeInterval = 5, tolerance: Double = 1) { self.quiet=quiet; self.maxWait=maxWait; self.tolerance=tolerance }
    public mutating func observe(_ frames: [String:Rect],at time: Date) -> Decision {
        guard let start=startedAt,let previous=last,let changedAt=lastChange else {
            startedAt=time; last=frames; lastChange=time; return .waiting
        }
        if changed(from:previous,to:frames) { last=frames; lastChange=time }
        if time.timeIntervalSince(lastChange ?? changedAt) >= quiet { return .settled }
        if time.timeIntervalSince(start) >= maxWait { return .timedOut }
        return .waiting
    }
    func changed(from a: [String:Rect],to b: [String:Rect]) -> Bool {
        guard Set(a.keys)==Set(b.keys) else { return true }
        return a.contains { key,r in
            guard let s=b[key] else { return true }
            return abs(r.x-s.x)>tolerance || abs(r.y-s.y)>tolerance || abs(r.width-s.width)>tolerance || abs(r.height-s.height)>tolerance
        }
    }
}
