// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore

/// Sends the anonymous daily count (`UsagePing`) at launch, then checks again every hour, on wake and when the
/// calendar day changes, so a Mac that stays on past midnight is counted on the new day too.
/// Fire-and-forget: one short GET, no cookies, no cache, no retries, errors ignored; nothing waits for it.
final class UsagePinger {
    private var timer: Timer?
    private var observers: [(NotificationCenter,NSObjectProtocol)]=[]
    private lazy var session: URLSession = {
        let c=URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest=10
        c.timeoutIntervalForResource=15
        c.waitsForConnectivity=false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache=nil
        c.httpCookieStorage=nil
        c.httpShouldSetCookies=false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration:c)
    }()

    /// Not for snapshot rendering, fixture or smoke test runs, or unbundled dev runs (no version in Info.plist).
    static var enabled: Bool {
        let args=CommandLine.arguments
        return !RenderMode.snapshot && Prefs.store != nil
            && !args.contains("--approved-fixture-test") && !args.contains("--smoke-report")
            && Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") is String
    }

    func start() {
        guard Self.enabled,timer == nil else { return }
        check()
        let t=Timer(timeInterval:3600,repeats:true) { [weak self] _ in self?.check() }
        t.tolerance=600
        RunLoop.main.add(t,forMode:.common)
        timer=t
        let ws=NSWorkspace.shared.notificationCenter
        observers.append((ws,ws.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in self?.check() }))
        let nc=NotificationCenter.default
        observers.append((nc,nc.addObserver(forName:.NSCalendarDayChanged,object:nil,queue:.main) { [weak self] _ in self?.check() }))
    }

    deinit {
        timer?.invalidate()
        for (center,token) in observers { center.removeObserver(token) }
    }

    func check() {
        guard Self.enabled,let store=Prefs.store,
              let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String else { return }
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0"
        let os=ProcessInfo.processInfo.operatingSystemVersion
        let payload=UsagePing.Payload(version:version,build:build,arch:UsagePing.buildArch,
                                      osMajor:os.majorVersion,osMinor:os.minorVersion,screens:NSScreen.screens.count)
        let plan=UsagePing.plan(lastDay:store.string(forKey:UsagePing.lastDayKey),installId:store.string(forKey:UsagePing.installIdKey),
                                now:Date(),payload:payload)
        if store.string(forKey:UsagePing.installIdKey) != plan.installId { store.set(plan.installId,forKey:UsagePing.installIdKey) }
        guard let url=plan.url else { return }
        // Marked before sending: a failed request waits for tomorrow instead of retrying.
        store.set(plan.day,forKey:UsagePing.lastDayKey)
        var request=URLRequest(url:url)
        request.httpMethod="GET"
        request.setValue(UsagePing.userAgent(payload),forHTTPHeaderField:"User-Agent")
        session.dataTask(with:request) { _,_,_ in }.resume()
    }
}
