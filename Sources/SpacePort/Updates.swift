// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import Sparkle

/// In-app updates (Sparkle 2). Checks only contact the feed in Info.plist (GitHub Releases); updates must carry
/// a valid EdDSA signature for SUPublicEDKey, and the new app is signed with the same certificate, so the
/// Accessibility permission carries over.
final class AppUpdater {
    let controller: SPUStandardUpdaterController
    init() { controller=SPUStandardUpdaterController(startingUpdater:true,updaterDelegate:nil,userDriverDelegate:nil) }
    /// Nil in builds without a feed (e.g. snapshot rendering).
    static func makeIfConfigured() -> AppUpdater? {
        guard !RenderMode.snapshot,Bundle.main.object(forInfoDictionaryKey:"SUFeedURL") != nil,Bundle.main.object(forInfoDictionaryKey:"SUPublicEDKey") != nil else { return nil }
        return AppUpdater()
    }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates=newValue }
    }
    func checkForUpdates() { NSApp.activate(ignoringOtherApps:true); controller.checkForUpdates(nil) }
}

/// `--update-check-and-install`: headless verification used by the release checklist. Checks the configured feed,
/// accepts the update, installs it without relaunching, logs each step to stdout and exits. Starts nothing else
/// (no status item, hotkeys, auto-restore or window access).
final class HeadlessUpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    static func log(_ s: String) { print("[update-test] \(s)"); fflush(stdout) }
    func start() {
        let u=SPUUpdater(hostBundle:.main,applicationBundle:.main,userDriver:self,delegate:self)
        updater=u
        do { try u.start() } catch { Self.log("start failed: \(error)"); exit(2) }
        Self.log("current version \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") ?? "?"), feed \(Bundle.main.object(forInfoDictionaryKey:"SUFeedURL") ?? "?")")
        u.checkForUpdates()
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }
    func show(_ request: SPUUpdatePermissionRequest,reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks:false,sendSystemProfile:false)) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { Self.log("checking…") }
    func showUpdateFound(with item: SUAppcastItem,state: SPUUserUpdateState,reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Self.log("update found: \(item.displayVersionString) (\(item.versionString)); installing"); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error,acknowledgement: @escaping () -> Void) { Self.log("no update: \(error.localizedDescription)"); acknowledgement(); exit(3) }
    func showUpdaterError(_ error: Error,acknowledgement: @escaping () -> Void) { Self.log("error: \(error.localizedDescription) \((error as NSError).userInfo)"); acknowledgement(); exit(4) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { Self.log("downloading…") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { Self.log("verifying signature and extracting…") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { Self.log("ready to install; exiting so the installer can replace the bundle"); reply(.install)
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { Self.log("exiting"); exit(0) } }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,retryTerminatingApplication: @escaping () -> Void) { Self.log("installing (terminated=\(applicationTerminated))") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool,acknowledgement: @escaping () -> Void) { Self.log("installed"); acknowledgement() }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
