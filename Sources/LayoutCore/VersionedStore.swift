// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

// A replacement cannot start until the previous bytes have been safely preserved.
public enum VersionedStore {
    public static func previousURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("previous.json")
    }
    public static func write(_ data: Data,to url: URL) throws {
        let manager=FileManager.default
        try manager.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if manager.fileExists(atPath:url.path) {
            let previous=try Data(contentsOf:url)
            try previous.write(to:previousURL(for:url),options:.atomic)
        }
        try data.write(to:url,options:.atomic)
    }
}
public enum MonitorLayoutStore {
    public static func load(from url: URL) throws -> MonitorLayoutRecord {
        let record=try JSONDecoder().decode(MonitorLayoutRecord.self,from:Data(contentsOf:url))
        try record.validate(); return record
    }
    public static func save(_ record: MonitorLayoutRecord,to url: URL) throws {
        try record.validate()
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try VersionedStore.write(encoder.encode(record),to:url)
    }
}
