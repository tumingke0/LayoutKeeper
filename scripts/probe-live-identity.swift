// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import AppKit
import Security
import ApplicationServices

// Reads only the existing LayoutKeeper GUI's code metadata. The AX boolean below belongs to this probe.
guard CommandLine.arguments.count==2,let pid=Int32(CommandLine.arguments[1]),
      let application=NSRunningApplication(processIdentifier:pid),application.bundleIdentifier=="local.layoutkeeper.app",
      let executable=application.executableURL,executable.path.hasSuffix("/dist/LayoutKeeper.app/Contents/MacOS/LayoutKeeper") else {
    fputs("Only the installed LayoutKeeper GUI PID is accepted\n",stderr); exit(2)
}
var live: SecCode?
let status=SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String: NSNumber(value:pid)] as CFDictionary,SecCSFlags(rawValue:0),&live)
guard status==errSecSuccess,let live else { fputs("Guest code unavailable: \(status)\n",stderr); exit(3) }
var code: SecStaticCode?
guard SecCodeCopyStaticCode(live,SecCSFlags(rawValue:0),&code)==errSecSuccess,let code else { exit(4) }
var info: CFDictionary?
guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,let data=info as? [String:Any] else { exit(5) }
var output: [String:Any]=["targetGUIPID":pid,"targetExecutable":executable.resolvingSymlinksInPath().path,
    "targetBundleIdentifier":application.bundleIdentifier!,"probePID":getpid(),
    "probeAXTrusted":AXIsProcessTrusted(),"probeAXScope":"Probe process only; not a query of the target GUI's TCC grant",
    "permissionPromptIssued":false,"targetCertificateCount":(data[kSecCodeInfoCertificates as String] as? [Any])?.count ?? 0,
    "targetSigningIdentifier":data[kSecCodeInfoIdentifier as String] ?? "unknown","targetTeamIdentifier":data[kSecCodeInfoTeamIdentifier as String] ?? "not set"]
if let hash=data[kSecCodeInfoUnique as String] as? Data { output["targetCDHash"]=hash.map{String(format:"%02x",$0)}.joined() }
var requirement: SecRequirement?
if SecCodeCopyDesignatedRequirement(code,SecCSFlags(rawValue:0),&requirement)==errSecSuccess,let requirement {
    var text: CFString?
    if SecRequirementCopyString(requirement,SecCSFlags(rawValue:0),&text)==errSecSuccess,let text { output["targetDesignatedRequirement"]=text as String }
}
print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
