// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// Anonymous daily count sent to GoatCounter (https://layoutkeeper.goatcounter.com), at most once per Mac per local
/// calendar day. It carries only the app version and build, the build's CPU architecture, the macOS major.minor
/// version, the number of screens as a bucket (1, 2, 3+) and a random install ID made on this Mac. No hardware IDs,
/// serial numbers, display names, user names, window titles, app lists or layouts.
///
/// Everything here is pure (no I/O) so it can be unit-tested; the app sends the request (`UsagePinger`).
public enum UsagePing {
    /// GoatCounter's public counting endpoint; no API token needed.
    public static let endpoint="https://layoutkeeper.goatcounter.com/count"
    public static let title="LayoutKeeper"
    /// UserDefaults keys.
    public static let installIdKey="usagePingInstallId"
    public static let lastDayKey="usagePingLastDay"

    public struct Payload: Equatable {
        public var version: String
        public var build: String
        public var arch: String
        public var osMajor: Int
        public var osMinor: Int
        public var screens: Int
        public init(version: String,build: String,arch: String,osMajor: Int,osMinor: Int,screens: Int) {
            self.version=version; self.build=build; self.arch=arch; self.osMajor=osMajor; self.osMinor=osMinor; self.screens=screens
        }
    }

    /// What is counted. Only `.launch` is sent today; a feature count would be one `.feature("input-switch")` call
    /// and shows up in GoatCounter as an event, apart from the daily launches.
    public enum Event: Equatable {
        case launch
        case feature(String)
    }

    /// Architecture this build was compiled for (the Intel build reports x86_64 even under Rosetta).
    public static var buildArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "other"
        #endif
    }

    /// Local calendar day, e.g. 2026-11-02.
    public static func dayKey(_ date: Date,calendar: Calendar = .current) -> String {
        let c=calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",c.year ?? 0,c.month ?? 0,c.day ?? 0)
    }

    public static func screenBucket(_ n: Int) -> String {
        if n<=1 { return "screens1" }
        if n==2 { return "screens2" }
        return "screens3plus"
    }

    /// Keeps a path segment to [A-Za-z0-9._-] (anything else becomes "_"), at most 32 characters.
    public static func segment(_ s: String) -> String {
        let allowed=Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned=String(s.prefix(32).map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }

    /// `/app/macos/0.6.16/arm64/macos27.0/screens2` for a launch; `/feature/<name>/0.6.16` for a feature event.
    public static func path(_ event: Event,_ p: Payload) -> String {
        switch event {
        case .launch:
            return "/app/macos/\(segment(p.version))/\(segment(p.arch))/macos\(p.osMajor).\(p.osMinor)/\(screenBucket(p.screens))"
        case .feature(let name):
            return "/feature/\(segment(name))/\(segment(p.version))"
        }
    }

    public static func url(_ event: Event,_ p: Payload,installId: String) -> URL? {
        guard var c=URLComponents(string:endpoint) else { return nil }
        let isEvent: Bool
        if case .feature = event { isEvent=true } else { isEvent=false }
        c.queryItems=[
            URLQueryItem(name:"p",value:path(event,p)),
            URLQueryItem(name:"t",value:title),
            URLQueryItem(name:"e",value:isEvent ? "true" : "false"),
            URLQueryItem(name:"uid",value:installId)
        ]
        return c.url
    }

    /// Looks like a Mac browser so GoatCounter's bot filter (zgo.at/isbot) counts it and files it under macOS.
    /// "Intel Mac OS X 10_15_7" is the frozen string every Mac browser sends, so it says nothing about this Mac.
    public static func userAgent(_ p: Payload) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) LayoutKeeper/\(segment(p.version)) (\(segment(p.build)))"
    }

    /// Random install ID (UUID v4, lower case), stored only in this Mac's preferences.
    public static func newInstallId() -> String { UUID().uuidString.lowercased() }

    public struct Plan: Equatable {
        /// nil when today's count was already sent.
        public var url: URL?
        public var installId: String
        public var day: String
    }

    /// Today's request, or nil if one already went out today. The caller stores `installId` and, when `url` is
    /// non-nil, `day` before sending: a failed send is not retried until the next day.
    public static func plan(lastDay: String?,installId: String?,now: Date,calendar: Calendar = .current,
                            payload: Payload,makeId: () -> String = newInstallId) -> Plan {
        let id=installId.flatMap { $0.isEmpty ? nil : $0 } ?? makeId()
        let today=dayKey(now,calendar:calendar)
        if lastDay == today { return Plan(url:nil,installId:id,day:today) }
        return Plan(url:url(.launch,payload,installId:id),installId:id,day:today)
    }
}
