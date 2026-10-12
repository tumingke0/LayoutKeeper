// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import Foundation
import LayoutCore
import MacAdapters

extension Model {
    func configureEmptyWindowTrial() {
        do {
            let trial=try EmptyWindowTrial.parse(arguments:CommandLine.arguments)
            emptyWindowTrial=trial;layoutStorageOverride=trial?.root
        } catch { trialConfigurationError="验收配置不合法，已阻止界面读写。请正常退出后检查验收目录。" }
    }
    func externalLayoutSnapshot(inspectionBudget:TimeInterval?=nil) throws -> Snapshot {
        guard trialConfigurationError.isEmpty else { throw LayoutError.invalidProfile }
        let ids=fixtures.filter{$0.isVisible && !$0.isMiniaturized && $0.title=="LayoutKeeper Fixture 1"}.map(\.windowNumber)
        let selected=currentExternalMonitor?.runtimeDisplayToken
        return try EmptyWindowTrial.capture(trial:emptyWindowTrial,createdWindowIDs:ids,regular:{ try windows.scan(selectedDisplayToken:selected,inspectionBudget:inspectionBudget) },owned:{ trial,ids in
            var snapshot=try windows.scan(onlyPID:getpid(),selectedDisplayToken:selected,inspectionBudget:inspectionBudget)
            snapshot.windows=snapshot.windows.filter{trial.accepts(token:$0.token,title:$0.selector.title,pid:getpid(),createdWindowIDs:ids)}
            return snapshot
        })
    }
}
