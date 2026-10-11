// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// A folder written by SpacePort (≤ 0.3.0). `layoutsSubpath == nil` means `root` itself is a Layouts folder
/// (the project-local Layouts used by build-products candidates); otherwise `root` is a whole data folder.
public struct LegacyDataSource: Equatable {
    public var root: URL
    public var layoutsSubpath: String?
    public init(root: URL, layoutsSubpath: String?) { self.root=root; self.layoutsSubpath=layoutsSubpath }
}

public struct DataMigrationResult: Codable, Equatable {
    public enum Status: String, Codable { case migrated, notNeeded, alreadyDone, failed }
    public var status: Status
    public var copiedFiles=0
    public var layouts=0
    public var skippedExisting=0
    public var sources: [String]=[]
    public var detail=""
    public var finishedAt: Date?
    public init(status: Status, detail: String = "") { self.status=status; self.detail=detail }
    public var summary: String {
        switch status {
        case .migrated: return "已从 SpacePort 复制 \(layouts) 份屏幕布局（共 \(copiedFiles) 个文件），旧文件夹保留未动。"
        case .alreadyDone: return "已完成过从 SpacePort 的迁移。"
        case .notNeeded: return detail.isEmpty ? "无需迁移。" : detail
        case .failed: return "从 SpacePort 迁移失败：\(detail)。旧文件夹保留未动，下次启动会重试。"
        }
    }
}

/// Copies (never moves or deletes) SpacePort data into the LayoutKeeper data folder on first launch.
/// Files are copied into a private staging folder, byte-compared and decoded, and only then moved into place.
/// Existing files in the target are never overwritten; the legacy folders are left intact as a backup.
public enum DataMigration {
    public static let markerName="migration-from-spaceport.json"
    public static func run(target: URL, sources: [LegacyDataSource], now: Date = Date()) -> DataMigrationResult {
        let fm=FileManager.default
        let marker=target.appendingPathComponent(markerName)
        if fm.fileExists(atPath:marker.path) { return DataMigrationResult(status:.alreadyDone) }
        if layoutCount(in:target.appendingPathComponent("Layouts/screens",isDirectory:true)) > 0 {
            var result=DataMigrationResult(status:.notNeeded,detail:"LayoutKeeper 文件夹里已有布局，没有迁移。")
            result.finishedAt=now; writeMarker(result,at:marker)
            return result
        }
        // relative path in the target tree → (source file, modification date). Newer file wins on conflicts.
        var plan=[String:(URL,Date)]()
        var used=[String]()
        for source in sources {
            var isDir: ObjCBool=false
            guard fm.fileExists(atPath:source.root.path,isDirectory:&isDir),isDir.boolValue else { continue }
            let files=regularFiles(under:source.root)
            guard !files.isEmpty else { continue }
            used.append(source.root.path)
            for (relative,url) in files {
                let mapped=source.layoutsSubpath == nil ? "Layouts/"+relative : relative
                let date=((try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
                if let existing=plan[mapped],existing.1 >= date { continue }
                plan[mapped]=(url,date)
            }
        }
        guard !plan.isEmpty else { return DataMigrationResult(status:.notNeeded,detail:"没有找到 SpacePort 的旧数据。") }
        let staging=target.appendingPathComponent(".migration-staging-\(UUID().uuidString)",isDirectory:true)
        defer { try? fm.removeItem(at:staging) }
        var result=DataMigrationResult(status:.migrated)
        result.sources=used
        do {
            for (relative,entry) in plan.sorted(by:{$0.key<$1.key}) {
                let staged=staging.appendingPathComponent(relative)
                try fm.createDirectory(at:staged.deletingLastPathComponent(),withIntermediateDirectories:true)
                try fm.copyItem(at:entry.0,to:staged)
                guard try Data(contentsOf:staged)==Data(contentsOf:entry.0) else { throw MigrationError("\(relative) 复制后内容不一致") }
                try verifyDecodes(relative:relative,source:entry.0,copy:staged)
            }
            for relative in plan.keys.sorted() {
                let destination=target.appendingPathComponent(relative)
                if fm.fileExists(atPath:destination.path) { result.skippedExisting += 1; continue }
                try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                try fm.moveItem(at:staging.appendingPathComponent(relative),to:destination)
                result.copiedFiles += 1
                if isLayout(relative) { result.layouts += 1 }
            }
        } catch {
            return DataMigrationResult(status:.failed,detail:"\(error)")
        }
        result.finishedAt=now
        writeMarker(result,at:marker)
        return result
    }
    struct MigrationError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description=d } }
    static func isLayout(_ relative: String) -> Bool {
        relative.hasPrefix("Layouts/screens/") && relative.hasSuffix(".json") && !relative.hasSuffix(".previous.json") && !relative.dropFirst("Layouts/screens/".count).contains("/")
    }
    /// A copy must decode whenever its source decodes (layouts incl. .previous.json, and restore journals).
    static func verifyDecodes(relative: String,source: URL,copy: URL) throws {
        if relative.hasPrefix("Layouts/screens/"),relative.hasSuffix(".json") {
            if (try? MonitorLayoutStore.load(from:source)) != nil,(try? MonitorLayoutStore.load(from:copy)) == nil { throw MigrationError("\(relative) 复制后无法读取") }
        } else if relative.hasPrefix("Layouts/transactions/"),relative.hasSuffix(".json") {
            let decode={ (url: URL) in try? JSONDecoder().decode(RestoreJournal.self,from:Data(contentsOf:url)) }
            if decode(source) != nil,decode(copy) == nil { throw MigrationError("\(relative) 复制后无法读取") }
        }
    }
    static func layoutCount(in directory: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []).filter{ $0.hasSuffix(".json") && !$0.hasSuffix(".previous.json") }.count
    }
    static func regularFiles(under root: URL) -> [(String,URL)] {
        guard let e=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[]) else { return [] }
        let base=root.standardizedFileURL.resolvingSymlinksInPath().path
        var out=[(String,URL)]()
        for case let url as URL in e {
            let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values?.isRegularFile == true,values?.isSymbolicLink != true,url.lastPathComponent != ".DS_Store",!url.lastPathComponent.hasPrefix(".migration-staging") else { continue }
            let path=url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base+"/") else { continue }
            out.append((String(path.dropFirst(base.count+1)),url))
        }
        return out
    }
    static func writeMarker(_ result: DataMigrationResult,at url: URL) {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? encoder.encode(result).write(to:url,options:.atomic)
    }
    public static func readMarker(in target: URL) -> DataMigrationResult? {
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf:target.appendingPathComponent(markerName))).flatMap{ try? decoder.decode(DataMigrationResult.self,from:$0) }
    }
}

/// Preferences written under the old bundle identifier are copied once into the new domain; existing keys win.
public enum DefaultsMigration {
    public static let markerKey="migratedPreferencesFromSpacePort"
    public static func keysToCopy(old: [String:Any],current: [String:Any]) -> [String:Any] {
        old.filter { key,_ in
            current[key] == nil && key != markerKey && !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple.")
        }
    }
}
