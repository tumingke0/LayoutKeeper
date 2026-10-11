// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// What the running system exposes for cross-Space moves, probed at runtime (no version table).
public struct CrossSpaceProbe: Codable, Equatable {
    public var skyLightLoaded: Bool
    public var moveOperationClass: Bool
    public var moveOperationABI: Bool
    public var membershipRead: Bool
    public var managedDisplaySpaces: Bool
    public var mainConnection: Bool
    public init(skyLightLoaded: Bool, moveOperationClass: Bool, moveOperationABI: Bool, membershipRead: Bool, managedDisplaySpaces: Bool, mainConnection: Bool) {
        self.skyLightLoaded=skyLightLoaded; self.moveOperationClass=moveOperationClass; self.moveOperationABI=moveOperationABI
        self.membershipRead=membershipRead; self.managedDisplaySpaces=managedDisplaySpaces; self.mainConnection=mainConnection
    }
    public static let all=CrossSpaceProbe(skyLightLoaded:true,moveOperationClass:true,moveOperationABI:true,membershipRead:true,managedDisplaySpaces:true,mainConnection:true)
    public static let none=CrossSpaceProbe(skyLightLoaded:false,moveOperationClass:false,moveOperationABI:false,membershipRead:false,managedDisplaySpaces:false,mainConnection:false)
    public var missing: [String] {
        var m=[String]()
        if !skyLightLoaded { m.append("SkyLight") }
        if !moveOperationClass { m.append("SLSBridgedMoveWindowsToManagedSpaceOperation") }
        else if !moveOperationABI { m.append("initWithWindows:spaceID:/performWithWMBridgeDelegate") }
        if !membershipRead { m.append("SLSCopySpacesForWindows") }
        if !managedDisplaySpaces { m.append("SLSCopyManagedDisplaySpaces") }
        if !mainConnection { m.append("SLSMainConnectionID") }
        return m
    }
}

public enum CrossSpaceSupport: Equatable {
    /// Capability present and this exact build passed the one-click self-test.
    case selfTested(version: String)
    /// Capability present but nobody has self-tested this build yet: allowed, per-window readback is the safety net.
    case untested(version: String)
    case unavailable(reason: String)
    public var enabled: Bool { if case .unavailable = self { return false }; return true }
    public var isUntested: Bool { if case .untested = self { return true }; return false }
    public var summary: String {
        switch self {
        case .selfTested: return "跨桌面恢复：可用"
        case .untested: return "跨桌面恢复：可用（此系统版本尚未自检）"
        case .unavailable: return "跨桌面恢复：不可用"
        }
    }
    public var detail: String {
        switch self {
        case .selfTested(let v): return "macOS \(v) 已通过一键自检。每个窗口移动后都会回读确认，失败会回滚。"
        case .untested(let v): return "macOS \(v) 具备所需的系统接口，但还没有在这个版本上运行过一键自检。仍然可以使用；每个窗口移动后都会回读确认，失败会回滚。建议先在「设置 → 诊断」运行一次自检。"
        case .unavailable(let r): return r+" 同一桌面内的位置和大小恢复、保存布局不受影响。"
        }
    }
}

public enum CrossSpaceGate {
    public static let minimumMajor=26
    /// Builds on which the one-click self-test passed (version + build), used only for the UI note.
    public static let selfTestedBuilds: Set<String>=["27.0/26A428"]
    public static func versionString(major: Int, minor: Int, patch: Int, build: String) -> String {
        (patch==0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)")+(build.isEmpty ? "" : " (\(build))")
    }
    public static func decide(major: Int, minor: Int, patch: Int, build: String, probe: CrossSpaceProbe) -> CrossSpaceSupport {
        let version=versionString(major:major,minor:minor,patch:patch,build:build)
        guard major>=minimumMajor else {
            return .unavailable(reason:"macOS \(version) 不支持跨桌面移动：macOS 14.5 起系统封锁了旧的移窗口接口，新的接口从 macOS 26 才提供。")
        }
        let missing=probe.missing
        guard missing.isEmpty else { return .unavailable(reason:"macOS \(version) 缺少跨桌面移动所需的系统接口（\(missing.joined(separator:"、"))），已关闭。") }
        let key=(patch==0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)")+"/"+build
        return selfTestedBuilds.contains(key) ? .selfTested(version:version) : .untested(version:version)
    }
}
