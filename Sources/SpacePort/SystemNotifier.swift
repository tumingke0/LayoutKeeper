// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import UserNotifications
import LayoutCore

/// A user-facing notice (restore result, save result, shared-mode hint…). Shown as a macOS notification:
/// clicking it opens LayoutKeeper, swiping it away dismisses it, its buttons are notification actions.
struct UserNotice {
    struct Action {
        var kind: NoticeAction
        var run: () -> Void
        init(_ kind: NoticeAction,run: @escaping () -> Void) { self.kind=kind; self.run=run }
    }
    var title: String
    var detail: String?=nil
    var actions: [Action]=[]
    /// 0: needs attention, stays in Notification Center until dismissed. Otherwise it is taken out of Notification
    /// Center after `NoticeRouting.retention(duration:)` (macOS times the banner itself).
    var duration: TimeInterval=2
    /// Clicking the notification itself; nil opens the main window.
    var open: (() -> Void)?=nil
    /// Called once when the notice goes away (clicked, an action, swiped away, replaced or expired).
    var onDismiss: (() -> Void)?=nil
}

/// Posts `UserNotice`s through UNUserNotificationCenter. One notice at a time, like the old in-app notice: a new one
/// replaces the previous (which is removed from Notification Center), so a stale button (e.g. Undo of an older
/// restore) can never run. Notifications from an earlier launch have no handlers; clicking them just opens the app.
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// nil without an app bundle (swift run, snapshot rendering): UNUserNotificationCenter.current() would trap there.
    private let center: UNUserNotificationCenter?
    var showMain: () -> Void={}
    var log: (String) -> Void={ _ in }
    /// The latest notice that macOS will not show as a banner (nil clears it). Shown in the menu-bar menu instead.
    var onMenuFallback: (UserNotice?) -> Void={ _ in }
    var onPermission: (NotificationPermission) -> Void={ _ in }
    private(set) var permission: NotificationPermission = .notDetermined
    private var requested=false
    private var registered=Set<String>()
    private var categories=Set<UNNotificationCategory>()
    private var current: (id: String,notice: UserNotice)?
    private var retentionTimer: Timer?

    override init() {
        let bundle=Bundle.main
        center=bundle.bundleIdentifier != nil && bundle.bundleURL.pathExtension == "app" && !RenderMode.snapshot ? UNUserNotificationCenter.current() : nil
        super.init()
    }
    /// Call before the app finishes launching so a click that launched the app is delivered to us.
    func start() {
        guard let center else { setPermission(.unavailable); return }
        center.delegate=self
        for set in NoticeRouting.knownActionSets { register(set,commit:false) }
        center.setNotificationCategories(categories)
        center.removeAllDeliveredNotifications()   // an earlier launch's buttons have no handlers any more
        refreshPermission()
    }
    func refreshPermission(_ done: ((NotificationPermission) -> Void)? = nil) {
        guard let center else { setPermission(.unavailable); done?(.unavailable); return }
        center.getNotificationSettings { [weak self] settings in
            let p=Self.permission(settings)
            DispatchQueue.main.async { self?.setPermission(p); done?(p) }
        }
    }
    private func setPermission(_ p: NotificationPermission) {
        guard p != permission || p == .unavailable else { return }
        permission=p; onPermission(p)
    }
    static func permission(_ s: UNNotificationSettings) -> NotificationPermission {
        switch s.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return s.alertSetting == .enabled && s.alertStyle != .none ? .allowed : .alertsOff
        }
    }

    func show(_ notice: UserNotice) {
        finishCurrent(removeDelivered:true)
        let id=UUID().uuidString
        current=(id,notice)
        if let r=NoticeRouting.retention(duration:notice.duration) {
            let t=Timer(timeInterval:r,repeats:false) { [weak self] _ in
                guard let self,self.current?.id == id else { return }
                self.finishCurrent(removeDelivered:true)
            }
            retentionTimer=t; RunLoop.main.add(t,forMode:.common)
        }
        deliver(id)
    }
    private func deliver(_ id: String) {
        refreshPermission { [weak self] p in
            guard let self,let cur=self.current,cur.id == id else { return }   // replaced meanwhile
            switch NoticeRouting.delivery(p,alreadyRequested:self.requested) {
            case .post: self.post(id,cur.notice,keepInMenu:false)
            case .postAndKeepInMenu: self.post(id,cur.notice,keepInMenu:true)
            case .menuOnly:
                self.log("notice not shown as notification (permission=\(p.rawValue)), kept in menu: \(cur.notice.title)")
                self.onMenuFallback(cur.notice)
            case .requestThenPost:
                self.requested=true
                // Banners only: the old in-app notices were silent, and a menu-bar app has no Dock badge.
                self.center?.requestAuthorization(options:[.alert]) { granted,error in
                    DispatchQueue.main.async {
                        self.log("notifications: authorization granted=\(granted) error=\(error.map{ "\($0)" } ?? "-")")
                        self.deliver(id)
                    }
                }
            }
        }
    }
    private func post(_ id: String,_ notice: UserNotice,keepInMenu: Bool) {
        guard let center else { return }
        let kinds=notice.actions.map(\.kind)
        register(kinds,commit:true)
        let content=UNMutableNotificationContent()
        content.title=notice.title
        if let detail=notice.detail { content.body=detail }
        content.categoryIdentifier=NoticeRouting.categoryID(kinds)
        content.threadIdentifier=NoticeRouting.threadID
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier:id,content:content,trigger:nil)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.log("notice post failed (\(error)), kept in menu: \(notice.title)")
                    if self.current?.id == id { self.onMenuFallback(notice) }
                } else if self.current?.id == id { self.onMenuFallback(keepInMenu ? notice : nil) }
            }
        }
    }
    private func register(_ kinds: [NoticeAction],commit: Bool) {
        let cid=NoticeRouting.categoryID(kinds)
        guard registered.insert(cid).inserted else { return }
        let actions=kinds.map { UNNotificationAction(identifier:$0.identifier,title:$0.title,options:$0.opensApp ? [.foreground] : []) }
        // customDismissAction: swiping the notification away is reported, so onDismiss runs like closing the old notice.
        categories.insert(UNNotificationCategory(identifier:cid,actions:actions,intentIdentifiers:[],options:[.customDismissAction]))
        if commit { center?.setNotificationCategories(categories) }
    }
    /// Ends the current notice: removes it from Notification Center (unless macOS already did) and runs onDismiss.
    private func finishCurrent(removeDelivered: Bool) {
        retentionTimer?.invalidate(); retentionTimer=nil
        guard let cur=current else { return }
        current=nil
        if removeDelivered { center?.removeDeliveredNotifications(withIdentifiers:[cur.id]) }
        cur.notice.onDismiss?()
    }

    // MARK: UNUserNotificationCenterDelegate
    /// LayoutKeeper is a menu-bar app that is often frontmost: still show the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification,withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse,withCompletionHandler completionHandler: @escaping () -> Void) {
        let id=response.notification.request.identifier, action=response.actionIdentifier
        DispatchQueue.main.async { [weak self] in self?.handle(id:id,action:action); completionHandler() }
    }
    func handle(id: String,action: String) {
        guard let cur=current,cur.id == id else {
            // From an earlier launch or already replaced: its buttons are stale, so never run them; a click opens the app.
            log("notice response for an old notification action=\(action)")
            if action != UNNotificationDismissActionIdentifier { showMain() }
            return
        }
        onMenuFallback(nil)
        switch action {
        case UNNotificationDismissActionIdentifier:
            finishCurrent(removeDelivered:false)
        case UNNotificationDefaultActionIdentifier:
            finishCurrent(removeDelivered:false)
            (cur.notice.open ?? showMain)()
        default:
            finishCurrent(removeDelivered:true)
            if let kind=NoticeAction(identifier:action),let a=cur.notice.actions.first(where:{ $0.kind == kind }) {
                log("notice action \(kind.rawValue)")
                a.run()
            } else { showMain() }
        }
    }

    /// Developer check (LAYOUTKEEPER_DEV_DIAG=1 --test-notification <out>): reports the permission, asks for it if
    /// never asked, posts one test notification and checks that macOS delivered it.
    static func selfCheck(out: URL) {
        var lines=["bundle=\(Bundle.main.bundleIdentifier ?? "-") path=\(Bundle.main.bundleURL.lastPathComponent)"]
        let center=UNUserNotificationCenter.current()
        let presenter=SystemNotifier(); center.delegate=presenter
        var done=false
        func finish() { try? lines.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8); done=true }
        func describe(_ s: UNNotificationSettings) -> String { "auth=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) style=\(s.alertStyle.rawValue) mapped=\(permission(s).rawValue)" }
        func postTest() {
            let c=UNMutableNotificationContent(); c.title=lk("LayoutKeeper 通知测试"); c.body=lk("这是一条测试通知，可以直接划掉。")
            let id="lk.selfcheck.\(UUID().uuidString)"
            center.add(UNNotificationRequest(identifier:id,content:c,trigger:nil)) { error in
                lines.append("add error=\(error.map{ "\($0)" } ?? "none")")
                DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                    center.getDeliveredNotifications { list in
                        lines.append("delivered=\(list.contains{ $0.request.identifier == id })")
                        DispatchQueue.main.async { finish() }
                    }
                }
            }
        }
        center.getNotificationSettings { s in
            lines.append("before: "+describe(s))
            if s.authorizationStatus == .notDetermined {
                center.requestAuthorization(options:[.alert]) { granted,error in
                    lines.append("request granted=\(granted) error=\(error.map{ "\($0)" } ?? "none")")
                    center.getNotificationSettings { s2 in lines.append("after: "+describe(s2)); postTest() }
                }
            } else { postTest() }
        }
        let deadline=Date().addingTimeInterval(60)
        while !done && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.2)) }
        if !done { lines.append("timed out"); finish() }
    }
}
