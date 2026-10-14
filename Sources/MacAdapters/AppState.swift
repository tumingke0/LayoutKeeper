// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import ApplicationServices
import LayoutCore

public struct ControlAccessState: Equatable {
    public let trusted: Bool?
    public let checkedAt: Date?
    public init(trusted: Bool? = nil, checkedAt: Date? = nil) { self.trusted=trusted; self.checkedAt=checkedAt }
    public var canReadWindows: Bool { trusted == true }
    public var title: String {
        guard let trusted else { return lk("正在检查系统控制权限") }
        return trusted ? lk("系统控制权限：已授权") : lk("系统控制权限：未授权")
    }
    public var guidance: String {
        guard let trusted else { return lk("正在读取当前应用的授权状态。") }
        return trusted ? lk("可以尝试保存可读取的软件窗口。") : lk("当前运行的 LayoutKeeper 尚未获得系统控制权限。打开系统设置允许 LayoutKeeper；返回后应用会自动检查。")
    }
}
public final class ControlAccessMonitor {
    public private(set) var state=ControlAccessState()
    private let query: () -> Bool
    public init(query: @escaping () -> Bool = AXIsProcessTrusted) { self.query=query }
    @discardableResult public func check(at date: Date = Date()) -> ControlAccessState {
        state=ControlAccessState(trusted:query(),checkedAt:date)
        return state
    }
}
public enum ControlSettings {
    /// Accessibility pane: the System Settings extension URL (macOS 13+, incl. 26/27), then the legacy pane URL,
    /// then System Settings itself.
    public static let accessibilityURLs=[
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ]
    public static func openAccessibility(using opener: (URL) -> Bool) -> Bool {
        for text in accessibilityURLs { if let url=URL(string:text),opener(url) { return true } }
        return opener(URL(fileURLWithPath:"/System/Applications/System Settings.app",isDirectory:true))
    }
    /// Shows the system Accessibility prompt. Only called from an explicit user click in the onboarding guide.
    @discardableResult public static func requestAccessibility(prompt: ([String:Any]) -> Bool = { AXIsProcessTrustedWithOptions($0 as CFDictionary) }) -> Bool {
        prompt([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true])
    }
    public static func open(using opener: (URL) -> Bool) -> Bool {
        let pane=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if opener(pane) { return true }
        return opener(URL(fileURLWithPath:"/System/Applications/System Settings.app",isDirectory:true))
    }
}
public enum AppInstallation {
    public static func fixedBundleURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Applications",isDirectory:true).appendingPathComponent("LayoutKeeper.app",isDirectory:true)
    }
    /// Where this copy runs from, with the home folder shown as "~" (e.g. "/Applications/LayoutKeeper.app").
    public static func location(bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path=bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath=home.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(homePath+"/") ? "~"+path.dropFirst(homePath.count) : path
    }
    /// A copy built from source: `scripts/build.sh` output (build-products) or a bare `swift build` binary (no .app bundle).
    public static func isDevelopmentBuild(bundleURL: URL) -> Bool {
        let path=bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return !path.hasSuffix(".app") || path.contains("/build-products/") || path.contains("/.build/")
    }
    /// Short role for diagnostics: "已安装" (installed) or "开发构建" (development build).
    public static func role(bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        isDevelopmentBuild(bundleURL:bundleURL) ? lk("开发构建") : lk("已安装")
    }
    public static let dataFolderName="LayoutKeeper"
    public static let legacyDataFolderName="SpacePort"
    /// ~/Library/Application Support/LayoutKeeper (layouts, transactions, self-test reports, migration marker).
    public static func dataDirectory(applicationSupport: URL) -> URL { applicationSupport.appendingPathComponent(dataFolderName,isDirectory:true) }
    /// Since 0.4.0 every build (installed or build-products candidate) uses the same data directory.
    public static func layoutDirectory(bundleURL: URL, applicationSupport: URL) -> URL {
        dataDirectory(applicationSupport:applicationSupport).appendingPathComponent("Layouts",isDirectory:true)
    }
    /// Where SpacePort (≤0.3.0) kept data: ~/Library/Application Support/SpacePort, and — for candidates run from the
    /// project's build-products/dist — the project's own Layouts folder. Used only as read-only migration sources.
    /// The project folder was renamed from space-port to LayoutKeeper in 0.5.0; both still count as "the project".
    public static let projectFolderNames: Set<String>=["space-port","LayoutKeeper"]
    public static func legacyDataSources(bundleURL: URL, applicationSupport: URL) -> [LegacyDataSource] {
        var sources=[LegacyDataSource(root:applicationSupport.appendingPathComponent(legacyDataFolderName,isDirectory:true),layoutsSubpath:"Layouts")]
        let root=bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if projectFolderNames.contains(root.lastPathComponent), ["dist","build-products"].contains(bundleURL.deletingLastPathComponent().lastPathComponent) {
            sources.append(LegacyDataSource(root:root.appendingPathComponent("Layouts",isDirectory:true),layoutsSubpath:nil))
        }
        return sources
    }
}

public enum ExternalSavePhase { case readWindows, validateScreen, capture, writeRecord }
public enum ExternalSaveMessage {
    public static func failure(error: Error, phase: ExternalSavePhase) -> String {
        if case EmptyWindowTrialError.fixtureRequired = error {
            return lk("当前处于空白验收模式，尚未创建空白测试窗口。请正常退出后重新打开固定应用，再保存正式布局。原有布局记录已保留。")
        }
        if case LayoutError.permissionRequired = error {
            return lk("当前应用的系统控制权限尚不可用。打开系统设置允许 LayoutKeeper，应用会自动检查。原有布局记录已保留。")
        }
        let reason: String
        switch phase {
        case .readWindows: reason=lk("窗口读取未完成，可以稍后重试。")
        case .validateScreen: reason=lk("保存时外接屏连接已改变，请保持屏幕连接后重试。")
        case .capture: reason=lk("无法可靠确认窗口布局，本次没有保存。")
        case .writeRecord: reason=lk("布局文件写入失败，请确认保存位置有可用空间且可以写入。")
        }
        return reason + lk("原有布局记录已保留。")
    }
}
