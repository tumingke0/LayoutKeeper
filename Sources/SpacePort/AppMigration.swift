// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import LayoutCore
import MacAdapters

/// First-launch migration from SpacePort: copies data (never moves/deletes) and old preferences.
enum AppMigration {
    static var lastResult: DataMigrationResult?
    static var applicationSupport: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
    }
    static func runAtLaunch() {
        let support=applicationSupport
        let target=AppInstallation.dataDirectory(applicationSupport:support)
        lastResult=DataMigration.run(target:target,sources:AppInstallation.legacyDataSources(bundleURL:Bundle.main.bundleURL,applicationSupport:support))
        migratePreferences()
    }
    static func migratePreferences() {
        let defaults=UserDefaults.standard
        guard !defaults.bool(forKey:DefaultsMigration.markerKey),let current=Bundle.main.bundleIdentifier,current != AppIdentity.legacyBundleIdentifier else { return }
        let old=defaults.persistentDomain(forName:AppIdentity.legacyBundleIdentifier) ?? [:]
        for (key,value) in DefaultsMigration.keysToCopy(old:old,current:defaults.persistentDomain(forName:current) ?? [:]) { defaults.set(value,forKey:key) }
        defaults.set(true,forKey:DefaultsMigration.markerKey)
    }
    static var statusText: String {
        let marker=DataMigration.readMarker(in:AppInstallation.dataDirectory(applicationSupport:applicationSupport))
        return (lastResult?.status == .alreadyDone ? marker : lastResult)?.summary ?? marker?.summary ?? lk("无需迁移。")
    }
}
