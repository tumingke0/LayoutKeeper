// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// What the main window should emphasise. "matches" comes from a read-only plan: nothing ready to restore and
/// nothing waiting for confirmation (windows that are closed or can't be restored don't count against it).
public enum MainWindowState: Equatable {
    case noMonitor, needsPermission, notSaved, checking
    case differs(ready: Int, needsConfirmation: Int)
    case matches(notRestorable: Int)
    public enum Primary: Equatable { case save, restore, none }
    public var primary: Primary {
        switch self {
        case .notSaved: return .save
        case .differs, .checking: return .restore
        case .matches, .noMonitor, .needsPermission: return .none
        }
    }
    public static func derive(hasMonitor: Bool,trusted: Bool,hasLayout: Bool,plan: QuickRestorePlan?) -> MainWindowState {
        guard hasMonitor else { return .noMonitor }
        guard trusted else { return .needsPermission }
        guard hasLayout else { return .notSaved }
        guard let plan else { return .checking }
        let ready=plan.items.filter{$0.state == .ready}.count
        let confirm=plan.items.filter{$0.state == .needsConfirmation}.count
        if ready>0 || confirm>0 { return .differs(ready:ready,needsConfirmation:confirm) }
        return .matches(notRestorable:plan.items.filter{$0.state == .blocked || $0.state == .missing}.count)
    }
}
