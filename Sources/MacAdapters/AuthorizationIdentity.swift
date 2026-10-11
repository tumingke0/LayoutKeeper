// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import Security
import ApplicationServices
import Darwin

public enum AuthorizationIdentity {
    public static func evidence(trusted: Bool? = nil) -> [String:Any] {
        let executable=Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ProcessInfo.processInfo.arguments.first ?? "unknown"
        let gui=Bundle.main.bundleIdentifier==AppIdentity.bundleIdentifier && executable.hasSuffix("/LayoutKeeper.app/Contents/MacOS/LayoutKeeper")
        var result: [String:Any]=[
            "pid":getpid(),"executablePath":executable,
            "bundlePath":Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "bundleIdentifier":Bundle.main.bundleIdentifier ?? "unbundled",
            "permissionOwner":gui ? "LayoutKeeper GUI process" : "Calling CLI/probe process; does not measure GUI permission",
            "installationRole":gui ? AppInstallation.role(bundleURL:Bundle.main.bundleURL) : "CLI/probe",
            "callingProcessAccessibilityTrusted":trusted ?? AXIsProcessTrusted(),
            "permissionPromptIssued":false,"helperPresent":false]
        var live: SecCode?
        let codeStatus=SecCodeCopySelf(SecCSFlags(rawValue:0),&live)
        result["liveCodeStatus"]=codeStatus
        guard codeStatus==errSecSuccess, let live else { return result }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(live,SecCSFlags(rawValue:0),&code)==errSecSuccess,let code else { return result }
        var information: CFDictionary?
        let status=SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&information)
        result["signingInformationStatus"]=status
        if let info=information as? [String:Any] {
            result["signingIdentifier"]=info[kSecCodeInfoIdentifier as String] ?? "unknown"
            result["teamIdentifier"]=info[kSecCodeInfoTeamIdentifier as String] ?? "not set"
            result["certificateCount"]=(info[kSecCodeInfoCertificates as String] as? [Any])?.count ?? 0
            if let hash=info[kSecCodeInfoUnique as String] as? Data { result["cdhash"]=hash.map{String(format:"%02x",$0)}.joined() }
        }
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(code,SecCSFlags(rawValue:0),&requirement)==errSecSuccess,let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement,SecCSFlags(rawValue:0),&text)==errSecSuccess,let text { result["designatedRequirement"]=text as String }
        }
        return result
    }
}
