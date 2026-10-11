// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import Foundation
import LayoutCore

public enum EmptyWindowTrialError: Error, Equatable { case fixtureRequired }

public struct EmptyWindowTrial {
    public let root: URL
    private static func validated(_ path: String) throws -> EmptyWindowTrial {
        guard path.hasPrefix("/") else { throw LayoutError.invalidProfile }
        let root=URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
        let allowed=[URL(fileURLWithPath:"/tmp",isDirectory:true),FileManager.default.temporaryDirectory].map{$0.resolvingSymlinksInPath().standardizedFileURL}
        guard root.lastPathComponent=="Layouts",root.deletingLastPathComponent().lastPathComponent.hasPrefix("spaceport-trial-"),
              allowed.contains(where:{root.deletingLastPathComponent().deletingLastPathComponent()==$0}) else { throw LayoutError.invalidProfile }
        return EmptyWindowTrial(root:root)
    }
    public static func parse(arguments: [String]) throws -> EmptyWindowTrial? {
        let matches=arguments.indices.filter{arguments[$0]=="--approved-empty-window-trial"}
        guard !matches.isEmpty else { return nil }
        guard matches.count==1,let index=matches.first,arguments.count>index+1 else { throw LayoutError.invalidProfile }
        return try validated(arguments[index+1])
    }
    public static func capture<T>(trial: EmptyWindowTrial?, createdWindowIDs: [Int], regular: () throws -> T, owned: (EmptyWindowTrial,[Int]) throws -> T) throws -> T {
        guard let trial else { return try regular() }
        guard !createdWindowIDs.isEmpty else { throw EmptyWindowTrialError.fixtureRequired }
        return try owned(trial,createdWindowIDs)
    }
    public func accepts(token: String,title: String,pid: Int32,createdWindowIDs: [Int]) -> Bool {
        title=="LayoutKeeper Fixture 1" && createdWindowIDs.contains{token=="\(pid):\($0)"}
    }
}
