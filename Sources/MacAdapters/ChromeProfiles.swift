// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import LayoutCore

/// Reads Chrome's local profile list ("Local State") and each profile's recent session files, read-only.
/// Nothing is copied, kept or sent anywhere; the data only lives for one save or restore.
/// Read fresh on every call (a 3 s cache only collapses the several reads of one restore). A refusal is not
/// remembered: access can be granted while the app runs, and stale sessions would miss newly opened pages.
public enum ChromeProfiles {
    /// Result of the last read ("ok …" or why nothing could be read), for the restore log.
    public private(set) static var lastStatus="notLoaded"
    private static var cache: (Date,ChromeProfileResolver?)?
    public static func load(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome",isDirectory:true),
                            maxSessionBytes: Int = 64<<20,recentDays: Double = 14,maxAge: TimeInterval = 3) -> ChromeProfileResolver? {
        if let (at,value)=cache,Date().timeIntervalSince(at)<maxAge { return value }
        let value=read(root:root,maxSessionBytes:maxSessionBytes,recentDays:recentDays)
        cache=(Date(),value)
        return value
    }
    private static func read(root: URL,maxSessionBytes: Int,recentDays: Double) -> ChromeProfileResolver? {
        let data: Data
        do { data=try Data(contentsOf:root.appendingPathComponent("Local State")) }
        catch {
            let ns=error as NSError
            let perm=(ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code==Int(EPERM) || ns.code==NSFileReadNoPermissionError
            lastStatus=perm ? "localStateDenied" : (ns.code==NSFileReadNoSuchFileError ? "noChrome" : "localStateError(\(ns.code))")
            return nil
        }
        guard let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let profile=json["profile"] as? [String:Any],let info_cache=profile["info_cache"] as? [String:Any] else { lastStatus="localStateUnparsable"; return nil }
        let fm=FileManager.default, cutoff=Date().addingTimeInterval(-recentDays*86_400)
        var folders=[ChromeProfileResolver.Folder](), notes=[String]()
        for (id,value) in info_cache.sorted(by:{$0.key<$1.key}) {
            guard let info=value as? [String:Any] else { continue }
            let sessions=root.appendingPathComponent(id,isDirectory:true).appendingPathComponent("Sessions",isDirectory:true)
            var session=Data(), total=0
            if let files=try? fm.contentsOfDirectory(at:sessions,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey]) {
                // Every recent Session_ file, not only the newest: Chrome can keep two live ones while rotating,
                // and a window's pages may only be logged in the older one.
                for url in files where url.lastPathComponent.hasPrefix("Session_") {
                    guard let v=try? url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey]),let d=v.contentModificationDate,d>cutoff else { continue }
                    let size=v.fileSize ?? 0
                    guard total+size<=maxSessionBytes,let bytes=try? Data(contentsOf:url) else { notes.append("\(id):fileSkipped"); continue }
                    session.append(bytes); total+=size
                }
                if session.isEmpty { notes.append("\(id):noRecentSession") }
            } else { notes.append("\(id):sessionsUnreadable") }
            var names=Set<String>()
            for key in ["name","gaia_given_name","gaia_name"] { if let n=info[key] as? String,!n.isEmpty { names.insert(n) } }
            if let full=info["gaia_name"] as? String,let first=full.split(separator:" ").first { names.insert(String(first)) }
            folders.append(.init(id:id,names:names,session:session))
        }
        lastStatus=folders.isEmpty ? "noProfiles" : "ok profiles=\(folders.count)"+(notes.isEmpty ? "" : " "+notes.joined(separator:","))
        return folders.isEmpty ? nil : ChromeProfileResolver(folders:folders)
    }
}
