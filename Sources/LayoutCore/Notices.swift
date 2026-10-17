// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// A button on a user-facing notice. Shown as a macOS notification action; the identifier is stable so a category
/// (the fixed set of buttons macOS knows about) can be registered before the notification is posted.
public enum NoticeAction: String, CaseIterable, Sendable {
    case view, retry, restoreNow, undo, openMissionControl, openSettings, saveNow
    public var title: String {
        switch self {
        case .view: return lk("查看")
        case .retry: return lk("重试")
        case .restoreNow: return lk("恢复布局")
        case .undo: return lk("撤销")
        case .openMissionControl: return lk("打开调度中心")
        case .openSettings: return lk("打开设置")
        case .saveNow: return lk("现在保存")
        }
    }
    static let prefix="lk.action."
    public var identifier: String { Self.prefix+rawValue }
    public init?(identifier: String) {
        guard identifier.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue:String(identifier.dropFirst(Self.prefix.count)))
    }
    /// Actions that need LayoutKeeper's own window in front.
    public var opensApp: Bool { self == .view }
}

/// Whether macOS will show our notifications. `alertsOff`: allowed, but the user chose the "None" style (no banner).
public enum NotificationPermission: String, Sendable { case notDetermined, allowed, alertsOff, denied, unavailable }

public enum NoticeDelivery: Equatable, Sendable {
    /// Post the notification.
    case post
    /// Post it (it lands in Notification Center) but no banner appears, so also keep it in the menu.
    case postAndKeepInMenu
    /// Ask for permission first (only once per launch), then decide again.
    case requestThenPost
    /// Can't be shown as a notification: keep it in the menu and log it.
    case menuOnly
}

public enum NoticeRouting {
    public static let threadID="layoutkeeper"
    static let categoryPrefix="lk.notice"
    /// One category per distinct set of buttons, e.g. "lk.notice.retry+view"; "lk.notice" has none.
    public static func categoryID(_ actions: [NoticeAction]) -> String {
        actions.isEmpty ? categoryPrefix : categoryPrefix+"."+actions.map(\.rawValue).joined(separator:"+")
    }
    /// Button sets the app uses, registered at launch so the first notification of each kind already has its buttons.
    /// A set not listed here is registered on first use.
    public static let knownActionSets: [[NoticeAction]]=[
        [], [.view], [.retry,.view], [.restoreNow,.view], [.undo,.view], [.retry,.undo,.view],
        [.restoreNow], [.undo], [.openMissionControl], [.openSettings], [.saveNow]
    ]
    /// macOS times the banner itself (about 5 s). A notice with a duration is removed from Notification Center after
    /// max(duration, this), so its buttons (e.g. Undo) don't outlive the moment, like the old in-app notice.
    public static let minimumRetention: TimeInterval=8
    /// nil: needs attention, stays in Notification Center until the user dismisses it.
    public static func retention(duration: TimeInterval) -> TimeInterval? { duration<=0 ? nil : max(duration,minimumRetention) }
    public static func delivery(_ permission: NotificationPermission,alreadyRequested: Bool) -> NoticeDelivery {
        switch permission {
        case .allowed: return .post
        case .alertsOff: return .postAndKeepInMenu
        case .notDetermined: return alreadyRequested ? .menuOnly : .requestThenPost
        case .denied, .unavailable: return .menuOnly
        }
    }
    /// Menu-bar fallback text: the title, and the detail shortened to one readable line.
    public static func menuSubtitle(_ detail: String?,limit: Int = 80) -> String? {
        guard let d=detail?.trimmingCharacters(in:.whitespacesAndNewlines),!d.isEmpty else { return nil }
        return d.count<=limit ? d : String(d.prefix(limit-1))+"…"
    }
}
