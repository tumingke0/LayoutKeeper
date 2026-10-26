// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation

/// UI language. Source strings are Simplified Chinese; English comes from `en.lproj/Localizable.strings` in the app bundle.
/// The language follows the system: macOS picks from the bundle's localizations (en, zh-Hans) with English as the
/// development region, so Chinese systems get Chinese and every other language gets English.
/// Without a strings table (unit tests, `swift build` binaries) the Chinese source text is used unchanged.
public enum Localization {
    public static let table: [String:String]? = {
        if let forced=ProcessInfo.processInfo.environment["LAYOUTKEEPER_LANG"] {
            return forced.hasPrefix("zh") ? nil : load()
        }
        let preferred=Bundle.main.preferredLocalizations.first ?? "en"
        return preferred.hasPrefix("zh") ? nil : load()
    }()
    public static var isEnglish: Bool { table != nil }
    /// "1 windows" → "1 window" (English only; the source language has no plural forms).
    static func singularize(_ s: String) -> String {
        guard s.contains("1 ") else { return s }
        var out=s
        for (plural,single) in [("windows","window"),("desktops","desktop"),("items","item"),("files","file"),("times","time"),("seconds","second"),("candidates","candidate"),("layouts","layout"),("elements","element")] {
            out=out.replacingOccurrences(of:"(?<![0-9./])1 \(plural)\\b",with:"1 \(single)",options:.regularExpression)
        }
        return out
    }
    private static func load() -> [String:String]? {
        var urls: [URL]=[]
        if let u=Bundle.main.url(forResource:"Localizable",withExtension:"strings",subdirectory:nil,localization:"en") { urls.append(u) }
        if let dir=ProcessInfo.processInfo.environment["LAYOUTKEEPER_STRINGS_DIR"] { urls.append(URL(fileURLWithPath:dir).appendingPathComponent("en.lproj/Localizable.strings")) }
        for u in urls { if let d=NSDictionary(contentsOf:u) as? [String:String] { return d } }
        return nil
    }
}

/// Localized UI text. `key` is the Chinese source with `%@` for each argument.
public func lk(_ key: String,_ args: String...) -> String {
    let template=Localization.table?[key] ?? key
    if args.isEmpty { return template }
    if Localization.isEnglish { return Localization.singularize(fill(template,args)) }
    return fill(template,args)
}

func fill(_ source: String,_ args: [String]) -> String {
    var template=source
    var out=""; var index=0
    while let r=template.range(of:"%(?:(\\d+)\\$)?@",options:.regularExpression) {
        out+=template[..<r.lowerBound]
        let token=template[r]
        let argIndex: Int
        if token.count > 2,let pos=Int(token.dropFirst().dropLast(2)),pos >= 1 {
            argIndex=pos-1
        } else {
            argIndex=index; index+=1
        }
        out += (argIndex < args.count ? args[argIndex] : "")
        template=String(template[r.upperBound...])
    }
    return out+template
}
