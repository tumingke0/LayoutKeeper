// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

public enum AppIdentity {
    public static let name="LayoutKeeper"
    /// Provisional until fixed signing: kept under the same `local.` convention as SpacePort's `local.spaceport.prototype`.
    public static let bundleIdentifier="local.layoutkeeper.app"
    public static let legacyBundleIdentifier="local.spaceport.prototype"
    public static let urlSchemes=["layoutkeeper","spaceport"]
}
