// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// Finds which Chrome profile folder a window belongs to. All profiles share one Chrome process, so neither
/// Accessibility nor the process arguments say it. What does:
/// 1. each profile's session files list the pages (URL, UTF-8) and page titles (UTF-16) open in that profile; the
///    window's current page or title found in exactly one profile names the folder (`sessionsURL` / `sessionsTitle`);
/// 2. otherwise the profile name in the window title, when exactly one profile in Local State carries that name
///    (`localStateName`);
/// 3. otherwise unknown, and matching falls back to the title's display name.
/// The profile name in the title is also a check: a session hit in a profile with a different name is not trusted.
public struct ChromeProfileResolver {
    public struct Folder { public var id: String; public var names: Set<String>; public var session: Data
        public init(id: String,names: Set<String>,session: Data) { self.id=id; self.names=names; self.session=session } }
    public enum Source: String { case sessionsURL, sessionsTitle, localStateName, remembered, unknown }
    public struct Resolution: Equatable { public var folder: String?; public var source: Source; public var reason: String
        public var logText: String { (folder ?? "-")+" via=\(source.rawValue)"+(reason.isEmpty ? "" : "(\(reason))") } }
    public var folders: [Folder]
    public init(folders: [Folder]) { self.folders=folders }
    /// Last known folder per live window token ("pid:windowID"). Kept while Chrome runs (the token changes when Chrome
    /// relaunches), so a profile learned at one desk still identifies the window after moving to another monitor. Used only when a fresh resolution is ambiguous,
    /// never when the title's profile name no longer fits the remembered folder, nor for incognito/guest.
    public static var remembered=[String:String]()
    public static func forgetRemembered() { remembered.removeAll() }
    static func ambiguousOnly(_ r: Resolution) -> Bool {
        guard r.folder == nil,r.source == .unknown else { return false }
        return !["incognitoOrGuest","OnlyInOtherNamedProfile","nameNotInLocalState"].contains{ r.reason.contains($0) }
    }
    /// Resolves a live window, falling back to (and updating) the remembered folder for its token.
    public func resolve(token: String,_ w: ObservedWindow) -> Resolution {
        let fresh=resolve(w)
        if let f=fresh.folder {
            if Self.remembered.count>=512,Self.remembered[token] == nil { Self.remembered.removeAll() }   // bound: tokens of closed windows
            Self.remembered[token]=f; return fresh
        }
        guard Self.ambiguousOnly(fresh),let f=Self.remembered[token],let folder=folders.first(where:{ $0.id==f }) else { return fresh }
        if let p=BrowserTitles.profile(w.selector.title,bundleID:w.selector.bundleID),!folder.names.contains(p) { return fresh }
        return .init(folder:f,source:.remembered,reason:fresh.reason)
    }

    public func resolve(url: String?,title: String?,titleProfile: String?) -> Resolution {
        if titleProfile == BrowserTitles.incognito || titleProfile == BrowserTitles.guest { return .init(folder:nil,source:.unknown,reason:"incognitoOrGuest") }
        // Folders whose Local State names fit the title's profile name (all folders when the title shows no name).
        let named=titleProfile.map{ p in folders.filter{ $0.names.contains(p) } } ?? folders
        var notes=[String]()
        func pick(_ needle: Data?,_ source: Source,_ label: String) -> Resolution? {
            guard let needle else { notes.append("\(label)=none"); return nil }
            let hits=folders.filter{ $0.session.range(of:needle) != nil }
            let fit=hits.filter{ h in named.contains{ $0.id==h.id } }
            if fit.count==1 { return .init(folder:fit[0].id,source:source,reason:hits.count>1 ? "\(label)In\(hits.count)NarrowedByName" : "") }
            notes.append(hits.isEmpty ? "\(label)NotInSessions" : (fit.isEmpty ? "\(label)OnlyInOtherNamedProfile" : "\(label)In\(fit.count)Profiles"))
            return nil
        }
        var urlNeedle: Data?
        if let url,url.count>=12,!url.hasPrefix("chrome://") { urlNeedle=url.data(using:.utf8) }
        if let r=pick(urlNeedle,.sessionsURL,"url") { return r }
        var titleNeedle: Data?
        if let title { let t=BrowserTitles.normalize(title); if t.count>=4 { titleNeedle=t.data(using:.utf16LittleEndian) } }
        if let r=pick(titleNeedle,.sessionsTitle,"title") { return r }
        if titleProfile != nil {
            if named.count==1 { return .init(folder:named[0].id,source:.localStateName,reason:notes.joined(separator:",")) }
            notes.append(named.isEmpty ? "nameNotInLocalState" : "nameIn\(named.count)Profiles")
        } else { notes.append("noNameInTitle") }
        return .init(folder:nil,source:.unknown,reason:notes.joined(separator:","))
    }
    public func folder(url: String?,titleProfile: String?,title: String? = nil) -> String? { resolve(url:url,title:title,titleProfile:titleProfile).folder }
    public func resolve(_ w: ObservedWindow) -> Resolution {
        resolve(url:w.selector.document,title:w.selector.title,titleProfile:BrowserTitles.profile(w.selector.title,bundleID:w.selector.bundleID))
    }
    /// Live Chrome windows: token → resolution (known and unknown), for logging.
    public func resolveAll(_ windows: [ObservedWindow]) -> [(String,Resolution)] {
        windows.filter{ $0.selector.bundleID.hasPrefix("com.google.Chrome") }.map{ ($0.token,resolve(token:$0.token,$0)) }
    }
    /// Live window token → profile folder, for the restore planner.
    public func map(_ windows: [ObservedWindow]) -> [String:String] {
        var result=[String:String]()
        for (token,r) in resolveAll(windows) { if let f=r.folder { result[token]=f } }
        return result
    }
    /// Adds `browserProfile` to saved Chrome windows (left nil when unknown).
    public func tag(_ windows: [SavedWindow]) -> [SavedWindow] {
        windows.map { w in
            var w=w
            if w.selector.bundleID.hasPrefix("com.google.Chrome") {
                w.browserProfile=resolve(url:w.selector.document,title:w.selector.title,titleProfile:BrowserTitles.profile(w.selector.title,bundleID:w.selector.bundleID)).folder
            }
            return w
        }
    }
}
