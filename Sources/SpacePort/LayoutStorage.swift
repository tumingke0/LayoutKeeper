// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import LayoutCore
import MacAdapters

extension Model {
    /// Where layouts live; overridden by the empty-window trial so it never touches real data.
    var layoutDirectory: URL? {
        if let layoutStorageOverride { return layoutStorageOverride }
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        return AppInstallation.layoutDirectory(bundleURL:Bundle.main.bundleURL,applicationSupport:support)
    }
    /// Diagnostics/restore-log.txt in the data folder (reconnects and restores; no window titles).
    var restoreLog: RestoreLog? {
        guard !RenderMode.snapshot,layoutStorageOverride == nil else { return nil }
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        return RestoreLog(url:AppInstallation.dataDirectory(applicationSupport:support).appendingPathComponent("Diagnostics",isDirectory:true).appendingPathComponent("restore-log.txt"))
    }
    func logRestore(_ message: String) { restoreLog?.append(message) }
    /// Recently failed apps (last 24 h).
    var deferredRestoreBundles: Set<String> {
        let cutoff=Date().addingTimeInterval(-86_400)
        return Set(recentlyFailedBundles.filter{ $0.value>cutoff }.keys)
    }
    /// Wakes the saved apps (Electron accessibility switch, slow apps after sleep) and logs the ones that stay silent.
    func warmUpSavedApps(_ record: MonitorLayoutRecord) {
        let silent=windows.warmUp(bundleIDs:Set(record.profile.windows.map(\.selector.bundleID)))
        if !silent.isEmpty { logRestore("warm-up: not responding \(silent.joined(separator:","))") }
    }
}
