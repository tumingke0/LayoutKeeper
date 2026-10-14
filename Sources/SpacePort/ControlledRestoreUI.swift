// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore
import MacAdapters
import SpaceProbe

struct ControlledDispatchFailure: Error,CustomStringConvertible {
    let description: String
}
extension Model {
    /// Capability-based (macOS 26+ and the bridged move/readback symbols resolve); not a build allow-list.
    var crossSpaceSupport: CrossSpaceSupport {
        if let cachedCrossSpaceSupport { return cachedCrossSpaceSupport }
        let os=ProcessInfo.processInfo.operatingSystemVersion
        let build=NSDictionary(contentsOfFile:"/System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String ?? ""
        var raw=SPCrossSpaceSymbols(); SPProbeCrossSpaceSymbols(&raw)
        let probe=CrossSpaceProbe(skyLightLoaded:raw.skyLightLoaded != 0,moveOperationClass:raw.moveOperationClass != 0,moveOperationABI:raw.moveOperationABI != 0,
                                  membershipRead:raw.membershipRead != 0,managedDisplaySpaces:raw.managedDisplaySpaces != 0,mainConnection:raw.mainConnection != 0)
        var support=CrossSpaceGate.decide(major:os.majorVersion,minor:os.minorVersion,patch:os.patchVersion,build:build,probe:probe)
        // The native dispatcher applies its own copy of the gate; never enable the UI if they disagree.
        if support.enabled && SPControlledBridgeAvailable() != 1 { support = .unavailable(reason:lk("系统接口检测结果不一致，已关闭跨桌面移动。")) }
        cachedCrossSpaceSupport=support
        return support
    }
    var crossSpaceEnabled: Bool { crossSpaceSupport.enabled }
    func makeControlledMover(_ permits: [SpaceMovePermit],fixtureOnly: Bool = false) -> ControlledSpaces {
        ControlledSpaces(windows:windows,permits:permits,dispatch:{ proof,request in
            if fixtureOnly {
                guard proof.claim.axPID==getpid(),proof.selector.title=="LayoutKeeper Fixture 1",
                      self.fixtures.contains(where:{$0.windowNumber==Int(proof.claim.windowID) && $0.title=="LayoutKeeper Fixture 1" && $0.isVisible && !$0.isMiniaturized}) else { throw LayoutError.readbackUnavailable }
            }
            var detail=[CChar](repeating:0,count:512)
            let code=proof.claim.bundleID.withCString { bundle in
                (proof.selector.document ?? "").withCString { document in
                    proof.selector.title.withCString { title in
                        request.sourceDisplay.withCString { sourceDisplay in
                            request.targetDisplay.withCString { targetDisplay in
                                SPDispatchVerifiedWindow(proof.element,proof.claim.axPID,proof.claim.windowID,proof.claim.processStartedAt.timeIntervalSince1970,bundle,document,title,request.source,request.target,sourceDisplay,targetDisplay,&detail,512)
                            }
                        }
                    }
                }
            }
            guard code==0 else { throw ControlledDispatchFailure(description:String(cString:detail)) }
        })
    }
}
