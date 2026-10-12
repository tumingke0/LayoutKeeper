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
}
