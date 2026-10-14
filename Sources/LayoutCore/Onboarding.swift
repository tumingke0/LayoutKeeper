// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// First-run guide: 权限 → 开机自启 → 保存第一份布局. Pure state; the app supplies permission and login-item results.
public enum OnboardingStep: Int, CaseIterable, Equatable {
    case permission, launchAtLogin, firstLayout
    public var title: String {
        switch self { case .permission: return lk("权限"); case .launchAtLogin: return lk("开机自启"); case .firstLayout: return lk("保存第一份布局") }
    }
}
public enum OnboardingReason: Equatable {
    /// Never completed (or skipped) before: all three steps.
    case firstRun
    /// Completed before, but Accessibility is missing at launch (e.g. after a rebuild): only the permission step.
    case missingPermission
    /// Re-opened from Settings: all three steps.
    case reopened
}
public enum OnboardingPolicy {
    public static let completedKey="onboardingCompleted"
    public static func reasonAtLaunch(completed: Bool,trusted: Bool) -> OnboardingReason? {
        if !completed { return .firstRun }
        if !trusted { return .missingPermission }
        return nil
    }
}
public struct OnboardingFlow: Equatable {
    public let reason: OnboardingReason
    public let steps: [OnboardingStep]
    public private(set) var index=0
    public private(set) var permissionGranted: Bool
    public private(set) var finished=false
    public private(set) var skipped=false
    public init(reason: OnboardingReason,trusted: Bool) {
        self.reason=reason
        steps=reason == .missingPermission ? [.permission] : OnboardingStep.allCases
        permissionGranted=trusted
    }
    public var step: OnboardingStep { steps[index] }
    public var isLast: Bool { index == steps.count-1 }
    public var canGoBack: Bool { index>0 && !finished }
    /// The permission step can always be passed (the app still works read-only); the button just says so.
    public var primaryTitle: String {
        if step == .permission && !permissionGranted { return isLast ? lk("稍后再说") : lk("跳过这一步") }
        return isLast ? lk("完成") : lk("下一步")
    }
    /// Feed the latest AXIsProcessTrusted result (polled ~1 s). Returns true exactly once, when access was just
    /// granted while the permission step is shown — the UI shows a check mark and then calls `advance()`.
    @discardableResult public mutating func observePermission(_ trusted: Bool) -> Bool {
        let newlyGranted=trusted && !permissionGranted
        permissionGranted=trusted
        return newlyGranted && step == .permission && !finished
    }
    public mutating func advance() {
        guard !finished else { return }
        if isLast { finished=true } else { index+=1 }
    }
    public mutating func back() { if canGoBack { index-=1 } }
    public mutating func skip() { finished=true; skipped=true }
    /// Completing or skipping both mean "don't show the full guide again"; missing permission still re-shows step 1.
    public var marksCompleted: Bool { finished }
    public var stepLabel: String { lk("第 %@ 步，共 %@ 步", "\(index+1)", "\(steps.count)") }
}

public enum LaunchAtLoginStatus: Equatable {
    case enabled, disabled, requiresApproval, unavailable(String)
    public var isOn: Bool { self == .enabled || self == .requiresApproval }
    public var message: String? {
        switch self {
        case .enabled, .disabled: return nil
        case .requiresApproval: return lk("需要在“系统设置 → 通用 → 登录项”里允许 LayoutKeeper。")
        case .unavailable(let why): return lk("无法设置开机自启：%@", "\(why)")
        }
    }
}

/// "下次接上外接屏时提醒我": remind once, on a connect of a monitor that has no saved layout.
public enum FirstLayoutReminder {
    public static let key="remindToSaveFirstLayout"
    public static func shouldRemind(flag: Bool,monitorConnected: Bool,hasLayout: Bool,trusted: Bool) -> Bool {
        flag && monitorConnected && !hasLayout && trusted
    }
}
