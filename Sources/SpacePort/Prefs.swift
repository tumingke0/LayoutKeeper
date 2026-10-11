// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import LayoutCore

/// UserDefaults storage for LayoutKeeper preferences (per-monitor choices/names, pause, hotkeys).
enum Prefs {
    static let monitorPreferencesKey="monitorPreferences"
    static let pausedUntilKey="autoRestorePausedUntil"
    static let hotkeysKey="globalHotkeys"
    /// nil while rendering snapshots: sample data must never read or write the user's real preferences.
    static var store: UserDefaults? { RenderMode.snapshot ? nil : UserDefaults.standard }
    static func load<T: Decodable>(_ type: T.Type,key: String) -> T? {
        store?.data(forKey:key).flatMap{ try? JSONDecoder().decode(T.self,from:$0) }
    }
    static func save<T: Encodable>(_ value: T,key: String) {
        if let data=try? JSONEncoder().encode(value) { store?.set(data,forKey:key) }
    }
    static func monitorPreferences() -> MonitorPreferences { load(MonitorPreferences.self,key:monitorPreferencesKey) ?? MonitorPreferences() }
    static func hotkeys() -> HotkeySettings { load(HotkeySettings.self,key:hotkeysKey) ?? .defaults }
}

struct RestoreSummary: Equatable {
    var at: Date
    var restored: Int
    var needsConfirmation: Int
    var failed: Int
}
