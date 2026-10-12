// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// One saved screen in the main window's sidebar.
public struct SavedScreen: Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var monitor: MonitorIdentity
    public var name: String
    public var savedAt: Date
    public var windowCount: Int
    public var desktopCount: Int
    public var connected: Bool
    public init(key: String,monitor: MonitorIdentity,name: String,savedAt: Date,windowCount: Int,desktopCount: Int,connected: Bool) {
        self.key=key; self.monitor=monitor; self.name=name; self.savedAt=savedAt; self.windowCount=windowCount; self.desktopCount=desktopCount; self.connected=connected
    }
}

/// One version of a screen's layout: the current file or an archived earlier save.
public struct LayoutVersion: Equatable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var savedAt: Date
    public var windowCount: Int
    public var desktopCount: Int
    public var isCurrent: Bool
    /// A user label on a history version; labelled versions are never pruned.
    public var label: String?=nil
    public init(url: URL,savedAt: Date,windowCount: Int,desktopCount: Int,isCurrent: Bool,label: String? = nil) {
        self.label=label
        self.url=url; self.savedAt=savedAt; self.windowCount=windowCount; self.desktopCount=desktopCount; self.isCurrent=isCurrent
    }
}

public struct ScreenLibraryError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description=description }
}

/// A named layout (「版式」): pinned, user-created, never pruned.
public struct NamedLayout: Equatable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var savedAt: Date
    public var windowCount: Int
    public var desktopCount: Int
    /// Identical to the screen's current layout (it was the last one applied or saved from).
    public var isActive: Bool
    public init(url: URL,name: String,savedAt: Date,windowCount: Int,desktopCount: Int,isActive: Bool) {
        self.url=url; self.name=name; self.savedAt=savedAt; self.windowCount=windowCount; self.desktopCount=desktopCount; self.isActive=isActive
    }
}

/// File layout under the data folder's `screens/` directory:
///   `<key>.json`                current layout (what restore uses)
///   `<key>.previous.json`       kept by `VersionedStore` for compatibility
///   `history/<key>/<stamp>.json` up to `historyLimit` unlabelled earlier versions (labels in `history/<key>/names.idx`)
///   `named/<key>/<id>.json`      named layouts (names in `named/<key>/names.idx`)
/// The current file is the screen's default: auto-restore on connect always uses the last saved or applied layout.
/// Deleting a screen moves all of the above into `<data>/trash/<stamp>-<key>/`; nothing is erased.
public struct ScreenLibrary {
    public let root: URL
    public var historyLimit=5
    public init(root: URL,historyLimit: Int = 5) { self.root=root; self.historyLimit=historyLimit }

    public func currentURL(_ key: String) -> URL { root.appendingPathComponent("\(key).json") }
    public func historyDirectory(_ key: String) -> URL { root.appendingPathComponent("history",isDirectory:true).appendingPathComponent(key,isDirectory:true) }
    public func namedDirectory(_ key: String) -> URL { root.appendingPathComponent("named",isDirectory:true).appendingPathComponent(key,isDirectory:true) }
    public var trashDirectory: URL { root.deletingLastPathComponent().appendingPathComponent("trash",isDirectory:true) }

    public static func counts(_ record: MonitorLayoutRecord) -> (windows: Int,desktops: Int) {
        (record.profile.windows.count,Set(record.profile.windows.compactMap(\.desktopIndex)).count)
    }

    /// Every readable saved screen. Connected screen first, then most recently saved.
    public func screens(connectedKey: String?,name: (MonitorIdentity) -> String) -> [SavedScreen] {
        let files=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
        var result=[SavedScreen]()
        for url in files where url.pathExtension=="json" && !url.lastPathComponent.hasSuffix(".previous.json") {
            guard let record=try? MonitorLayoutStore.load(from:url),url.deletingPathExtension().lastPathComponent==record.monitor.key else { continue }
            let c=Self.counts(record)
            result.append(SavedScreen(key:record.monitor.key,monitor:record.monitor,name:name(record.monitor),savedAt:record.savedAt,
                                      windowCount:c.windows,desktopCount:c.desktops,connected:record.monitor.key==connectedKey))
        }
        return result.sorted { a,b in a.connected != b.connected ? a.connected : (a.savedAt != b.savedAt ? a.savedAt>b.savedAt : a.key<b.key) }
    }

    /// Current version first, then archived versions, newest first.
    public func versions(_ key: String) -> [LayoutVersion] {
        importLegacyPrevious(key)
        var result=[LayoutVersion]()
        if let record=try? MonitorLayoutStore.load(from:currentURL(key)) {
            let c=Self.counts(record)
            result.append(LayoutVersion(url:currentURL(key),savedAt:record.savedAt,windowCount:c.windows,desktopCount:c.desktops,isCurrent:true))
        }
        return result+archived(key)
    }
    func archived(_ key: String) -> [LayoutVersion] {
        let files=(try? FileManager.default.contentsOfDirectory(at:historyDirectory(key),includingPropertiesForKeys:nil)) ?? []
        let labels=Self.readIndex(historyDirectory(key))
        return files.filter{$0.pathExtension=="json"}.compactMap { url -> LayoutVersion? in
            guard let record=try? MonitorLayoutStore.load(from:url),record.monitor.key==key else { return nil }
            let c=Self.counts(record)
            return LayoutVersion(url:url,savedAt:record.savedAt,windowCount:c.windows,desktopCount:c.desktops,isCurrent:false,label:labels[url.lastPathComponent])
        }.sorted { $0.savedAt != $1.savedAt ? $0.savedAt>$1.savedAt : $0.url.lastPathComponent>$1.url.lastPathComponent }
    }

    /// Saves `record` as current; the replaced current layout is archived first (oldest beyond the limit are dropped).
    public func save(_ record: MonitorLayoutRecord) throws {
        let key=record.monitor.key
        importLegacyPrevious(key)
        if FileManager.default.fileExists(atPath:currentURL(key).path) { try archiveCurrent(key) }
        try MonitorLayoutStore.save(record,to:currentURL(key))
        prune(key)
    }

    /// Makes an archived version current. The version leaves the history and the replaced current layout enters it,
    /// so promoting the returned URL undoes the change.
    @discardableResult public func promote(_ version: URL,key: String) throws -> URL? {
        guard version.deletingLastPathComponent().standardizedFileURL==historyDirectory(key).standardizedFileURL else { throw ScreenLibraryError("不是这块屏幕的历史版本") }
        let record=try MonitorLayoutStore.load(from:version)
        guard record.monitor.key==key else { throw ScreenLibraryError("版本与屏幕不匹配") }
        var archivedCurrent: URL?
        if FileManager.default.fileExists(atPath:currentURL(key).path) { archivedCurrent=try archiveCurrent(key) }
        try MonitorLayoutStore.save(record,to:currentURL(key))
        try FileManager.default.removeItem(at:version)
        var labels=Self.readIndex(historyDirectory(key)); if labels.removeValue(forKey:version.lastPathComponent) != nil { try? Self.writeIndex(labels,historyDirectory(key)) }
        prune(key,keeping:archivedCurrent)
        return archivedCurrent
    }

    /// Moves the screen's current, previous and history files to the trash folder and returns that folder.
    @discardableResult public func delete(_ key: String,now: Date = Date()) throws -> URL {
        let fm=FileManager.default
        guard fm.fileExists(atPath:currentURL(key).path) else { throw ScreenLibraryError("没有这块屏幕的布局") }
        let bin=trashDirectory.appendingPathComponent("\(Self.stamp(now))-\(key)",isDirectory:true)
        try fm.createDirectory(at:bin,withIntermediateDirectories:true)
        try fm.moveItem(at:currentURL(key),to:bin.appendingPathComponent("\(key).json"))
        let previous=VersionedStore.previousURL(for:currentURL(key))
        if fm.fileExists(atPath:previous.path) { try fm.moveItem(at:previous,to:bin.appendingPathComponent(previous.lastPathComponent)) }
        if fm.fileExists(atPath:historyDirectory(key).path) { try fm.moveItem(at:historyDirectory(key),to:bin.appendingPathComponent("history",isDirectory:true)) }
        if fm.fileExists(atPath:namedDirectory(key).path) { try fm.moveItem(at:namedDirectory(key),to:bin.appendingPathComponent("named",isDirectory:true)) }
        return bin
    }

    /// Puts a deleted screen back. Refuses if a layout for that screen was saved since (never overwrites).
    public func undoDelete(_ bin: URL,key: String) throws {
        let fm=FileManager.default
        guard !fm.fileExists(atPath:currentURL(key).path) else { throw ScreenLibraryError("这块屏幕已有新保存的布局，没有覆盖") }
        let saved=bin.appendingPathComponent("\(key).json")
        guard fm.fileExists(atPath:saved.path) else { throw ScreenLibraryError("回收的布局文件不存在") }
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try fm.moveItem(at:saved,to:currentURL(key))
        let previous=bin.appendingPathComponent(VersionedStore.previousURL(for:currentURL(key)).lastPathComponent)
        if fm.fileExists(atPath:previous.path),!fm.fileExists(atPath:VersionedStore.previousURL(for:currentURL(key)).path) {
            try fm.moveItem(at:previous,to:VersionedStore.previousURL(for:currentURL(key)))
        }
        let history=bin.appendingPathComponent("history",isDirectory:true)
        if fm.fileExists(atPath:history.path),!fm.fileExists(atPath:historyDirectory(key).path) {
            try fm.createDirectory(at:historyDirectory(key).deletingLastPathComponent(),withIntermediateDirectories:true)
            try fm.moveItem(at:history,to:historyDirectory(key))
        }
        let named=bin.appendingPathComponent("named",isDirectory:true)
        if fm.fileExists(atPath:named.path),!fm.fileExists(atPath:namedDirectory(key).path) {
            try fm.createDirectory(at:namedDirectory(key).deletingLastPathComponent(),withIntermediateDirectories:true)
            try fm.moveItem(at:named,to:namedDirectory(key))
        }
        // Remove the trash folder only when nothing is left in it; leftovers (e.g. a conflicting history) stay recoverable.
        if (try? fm.contentsOfDirectory(atPath:bin.path))?.isEmpty == true { try? fm.removeItem(at:bin) }
    }

    // MARK: - labels and named layouts

    /// Labels a history version (empty clears). A labelled version stays in history but is exempt from pruning.
    public func labelVersion(_ version: URL,key: String,label: String?) throws {
        guard version.deletingLastPathComponent().standardizedFileURL==historyDirectory(key).standardizedFileURL,
              FileManager.default.fileExists(atPath:version.path) else { throw ScreenLibraryError("不是这块屏幕的历史版本") }
        var labels=Self.readIndex(historyDirectory(key))
        let t=Self.clean(label)
        labels[version.lastPathComponent]=t
        try Self.writeIndex(labels,historyDirectory(key))
        prune(key)
    }
    public func namedLayouts(_ key: String) -> [NamedLayout] {
        let dir=namedDirectory(key), names=Self.readIndex(dir)
        let current=try? Data(contentsOf:currentURL(key))
        let files=(try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? []
        return files.filter{$0.pathExtension=="json"}.compactMap { url -> NamedLayout? in
            guard let data=try? Data(contentsOf:url),let record=try? MonitorLayoutStore.load(from:url),record.monitor.key==key else { return nil }
            let c=Self.counts(record)
            return NamedLayout(url:url,name:names[url.lastPathComponent] ?? "未命名",savedAt:record.savedAt,windowCount:c.windows,desktopCount:c.desktops,isActive:data==current)
        }.sorted { $0.url.deletingPathExtension().lastPathComponent<$1.url.deletingPathExtension().lastPathComponent }   // creation order
    }
    /// Saves the current layout or a history version as a named layout (a copy; the source is untouched).
    @discardableResult public func saveNamed(from source: URL,key: String,name: String,now: Date = Date()) throws -> URL {
        guard let n=Self.clean(name) else { throw ScreenLibraryError("请输入名字") }
        guard isOwn(source,key:key) else { throw ScreenLibraryError("不是这块屏幕的布局") }
        let record=try MonitorLayoutStore.load(from:source)
        guard record.monitor.key==key else { throw ScreenLibraryError("版本与屏幕不匹配") }
        let dir=namedDirectory(key)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var url=dir.appendingPathComponent("\(Self.stamp(now)).json"); var i=2
        while FileManager.default.fileExists(atPath:url.path) { url=dir.appendingPathComponent("\(Self.stamp(now))-\(i).json"); i+=1 }
        try Data(contentsOf:source).write(to:url,options:.atomic)
        var names=Self.readIndex(dir); names[url.lastPathComponent]=n; try Self.writeIndex(names,dir)
        return url
    }
    public func renameNamed(_ url: URL,key: String,name: String) throws {
        guard let n=Self.clean(name) else { throw ScreenLibraryError("请输入名字") }
        guard url.deletingLastPathComponent().standardizedFileURL==namedDirectory(key).standardizedFileURL,FileManager.default.fileExists(atPath:url.path) else { throw ScreenLibraryError("不是这块屏幕的版式") }
        var names=Self.readIndex(namedDirectory(key)); names[url.lastPathComponent]=n; try Self.writeIndex(names,namedDirectory(key))
    }
    /// Moves a named layout to the trash; `undoDeleteNamed` puts it back with its name.
    @discardableResult public func deleteNamed(_ url: URL,key: String,now: Date = Date()) throws -> URL {
        let dir=namedDirectory(key)
        guard url.deletingLastPathComponent().standardizedFileURL==dir.standardizedFileURL,FileManager.default.fileExists(atPath:url.path) else { throw ScreenLibraryError("不是这块屏幕的版式") }
        var names=Self.readIndex(dir)
        let bin=trashDirectory.appendingPathComponent("\(Self.stamp(now))-named-\(key)",isDirectory:true)
        try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:url,to:bin.appendingPathComponent(url.lastPathComponent))
        try Self.writeIndex([url.lastPathComponent:names[url.lastPathComponent] ?? "未命名"],bin)
        names.removeValue(forKey:url.lastPathComponent); try Self.writeIndex(names,dir)
        return bin
    }
    public func undoDeleteNamed(_ bin: URL,key: String) throws {
        let fm=FileManager.default, dir=namedDirectory(key), saved=Self.readIndex(bin)
        guard let (file,name)=saved.first else { throw ScreenLibraryError("回收的版式不存在") }
        guard !fm.fileExists(atPath:dir.appendingPathComponent(file).path) else { throw ScreenLibraryError("同名文件已存在，没有覆盖") }
        try fm.createDirectory(at:dir,withIntermediateDirectories:true)
        try fm.moveItem(at:bin.appendingPathComponent(file),to:dir.appendingPathComponent(file))
        var names=Self.readIndex(dir); names[file]=name; try Self.writeIndex(names,dir)
        try? fm.removeItem(at:bin)
    }
    /// Makes a named layout or history version the current (default) layout. Returns the URL to `apply` to undo:
    /// the archived former current, or — when the former current is already kept as a named layout — that layout.
    @discardableResult public func apply(_ source: URL,key: String) throws -> URL? {
        if source.deletingLastPathComponent().standardizedFileURL==historyDirectory(key).standardizedFileURL { return try promote(source,key:key) }
        guard source.deletingLastPathComponent().standardizedFileURL==namedDirectory(key).standardizedFileURL else { throw ScreenLibraryError("不是这块屏幕的版式") }
        let data=try Data(contentsOf:source)
        guard try MonitorLayoutStore.load(from:source).monitor.key==key else { throw ScreenLibraryError("版本与屏幕不匹配") }
        var undo: URL?
        if let current=try? Data(contentsOf:currentURL(key)) {
            if current==data { return nil }
            if let kept=namedLayouts(key).first(where:{ $0.isActive }) { undo=kept.url }   // already pinned: don't add a duplicate to history
            else { undo=try archiveCurrent(key) }
        }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try data.write(to:currentURL(key),options:.atomic)
        prune(key,keeping:undo)
        return undo
    }
    func isOwn(_ url: URL,key: String) -> Bool {
        let parent=url.deletingLastPathComponent().standardizedFileURL
        return url.standardizedFileURL==currentURL(key).standardizedFileURL || parent==historyDirectory(key).standardizedFileURL || parent==namedDirectory(key).standardizedFileURL
    }
    static func clean(_ s: String?) -> String? {
        guard let t=s?.trimmingCharacters(in:.whitespacesAndNewlines),!t.isEmpty else { return nil }
        return String(t.prefix(40))
    }
    static func readIndex(_ dir: URL) -> [String:String] {
        guard let data=try? Data(contentsOf:dir.appendingPathComponent("names.idx")) else { return [:] }
        return (try? JSONDecoder().decode([String:String].self,from:data)) ?? [:]
    }
    static func writeIndex(_ index: [String:String],_ dir: URL) throws {
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(index).write(to:dir.appendingPathComponent("names.idx"),options:.atomic)
    }

    // MARK: - internals
    @discardableResult func archiveCurrent(_ key: String) throws -> URL {
        let data=try Data(contentsOf:currentURL(key))
        let record=try MonitorLayoutStore.load(from:currentURL(key))
        try FileManager.default.createDirectory(at:historyDirectory(key),withIntermediateDirectories:true)
        var url=historyDirectory(key).appendingPathComponent("\(Self.stamp(record.savedAt)).json")
        var n=2
        while FileManager.default.fileExists(atPath:url.path) { url=historyDirectory(key).appendingPathComponent("\(Self.stamp(record.savedAt))-\(n).json"); n+=1 }
        try data.write(to:url,options:.atomic)
        return url
    }
    func prune(_ key: String,keeping: URL? = nil) {
        let list=archived(key).filter { $0.label == nil }
        guard list.count>historyLimit else { return }
        for v in list.dropFirst(historyLimit) where v.url != keeping { try? FileManager.default.removeItem(at:v.url) }
    }
    /// The first time history is used for a screen, the single `.previous.json` kept by older versions becomes its first entry.
    func importLegacyPrevious(_ key: String) {
        let fm=FileManager.default
        let previous=VersionedStore.previousURL(for:currentURL(key))
        guard !fm.fileExists(atPath:historyDirectory(key).path) else { return }
        guard fm.fileExists(atPath:previous.path),let record=try? MonitorLayoutStore.load(from:previous),record.monitor.key==key,
              (try? fm.createDirectory(at:historyDirectory(key),withIntermediateDirectories:true)) != nil else { return }
        try? fm.copyItem(at:previous,to:historyDirectory(key).appendingPathComponent("\(Self.stamp(record.savedAt)).json"))
    }
    static func stamp(_ date: Date) -> String {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(identifier:"UTC"); f.dateFormat="yyyyMMdd'T'HHmmss'Z'"
        return f.string(from:date)
    }
}
