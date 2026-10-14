// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore

/// In-app language choice (Settings → General → Language). Stored as LayoutKeeper's own "AppleLanguages" preference,
/// the standard per-app language override that macOS also sets from System Settings → Language & Region → Applications.
/// "Follow System" removes the override. Takes effect on the next launch.
enum AppLanguage: String, CaseIterable {
    case system, english, chinese
    private static let key="AppleLanguages"
    static var current: AppLanguage {
        get {
            guard let store=Prefs.store,let id=Bundle.main.bundleIdentifier,
                  let langs=store.persistentDomain(forName:id)?[key] as? [String],let first=langs.first else { return .system }
            return first.hasPrefix("zh") ? .chinese : (first.hasPrefix("en") ? .english : .system)
        }
        set {
            guard let store=Prefs.store else { return }
            switch newValue {
            case .system: store.removeObject(forKey:key)
            case .english: store.set(["en"],forKey:key)
            case .chinese: store.set(["zh-Hans"],forKey:key)
            }
        }
    }
    /// The choice that was in effect when this process started.
    static let atLaunch=current
    /// Quits and opens this same app bundle again once this process has exited.
    static func relaunch() {
        let path=Bundle.main.bundleURL.path
        let task=Process()
        task.executableURL=URL(fileURLWithPath:"/bin/sh")
        task.arguments=["-c","while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
