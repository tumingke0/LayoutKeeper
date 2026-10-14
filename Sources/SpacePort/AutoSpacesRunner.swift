// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import LayoutCore
import MacAdapters

/// Experimental, off by default. Adds missing Spaces on the external display / removes empty migrated Spaces on the
/// built-in display by driving Mission Control. Every step is verified by a SkyLight readback; any surprise aborts the run,
/// closes Mission Control and falls back to the phase-1 notice.
final class AutoSpacesRunner {
    private let driver=MissionControlDriver()
    private let spaces: ReadOnlySpaces
    private let queue=DispatchQueue(label:"layoutkeeper.autospaces")
    private(set) var running=false
    init(spaces: ReadOnlySpaces) { self.spaces=spaces }

    struct RunError: Error, CustomStringConvertible { var description: String }

    /// Full frame (top-left global coordinates, like AX) of the display with that token.
    static func screenFrame(token: String) -> CGRect? {
        let screens=NSScreen.screens
        let top=screens.first?.frame.maxY ?? 0
        for s in screens {
            guard let n=s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid=CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  (CFUUIDCreateString(nil,uuid)! as String).caseInsensitiveCompare(token) == .orderedSame else { continue }
            return CGRect(x:s.frame.minX,y:top-s.frame.maxY,width:s.frame.width,height:s.frame.height)
        }
        return nil
    }
    private func ordinary(on token: String) throws -> (ids: [UInt64],all: [Space]) {
        let all=try spaces.spaces(displays:MacEnvironment.displays())
        return (all.filter{ $0.displayToken.caseInsensitiveCompare(token) == .orderedSame && $0.kind == .ordinary }.map(\.id),all)
    }
    private func waitFor(_ deadline: Date,_ check: () throws -> Bool) rethrows -> Bool {
        let end=min(deadline,Date().addingTimeInterval(AutoSpaces.stepTimeout))
        while Date()<end { if try check() { return true }; Thread.sleep(forTimeInterval:0.15) }
        return try check()
    }

    /// Adds `count` Spaces to the display `token`. Completion runs on main with the number actually added or an error.
    func add(count: Int,token: String,completion: @escaping (Result<Int,RunError>) -> Void) {
        guard !running else { return completion(.failure(RunError(description:"上一次操作还没结束"))) }
        running=true
        queue.async { [self] in
            let deadline=Date().addingTimeInterval(AutoSpaces.runTimeout)
            var added=0
            let result: Result<Int,RunError>
            do {
                guard count>0,count<=AutoSpaces.maxPerRun else { throw RunError(description:"数量超出上限") }
                guard let frame=Self.screenFrame(token:token) else { throw RunError(description:"找不到外接屏") }
                try driver.open()
                for _ in 0..<count {
                    guard Date()<deadline else { throw RunError(description:"超时") }
                    let before=try ordinary(on:token)
                    guard !AutoSpaces.fullScreenActive(before.all) else { throw RunError(description:AutoSpaces.Blocker.fullScreenActive.description) }
                    try driver.pressAdd(screen:frame)
                    let ok=try waitFor(deadline) { AutoSpaces.verifyAdded(before:before.ids,after:try ordinary(on:token).ids) }
                    guard ok else { throw RunError(description:"按「+」后桌面数量没有按预期增加") }
                    added+=1
                }
                result = .success(added)
            } catch let e as RunError { result = .failure(RunError(description:e.description+(added>0 ? "（已加 \(added) 个）" : "")))
            } catch { result = .failure(RunError(description:"\(error)"+(added>0 ? "（已加 \(added) 个）" : ""))) }
            driver.close()
            DispatchQueue.main.async { self.running=false; completion(result) }
        }
    }

    /// Removes exactly the given Spaces from display `token`, re-checking before each one that it is still empty and inactive.
    func remove(ids: [UInt64],token: String,completion: @escaping (Result<Int,RunError>) -> Void) {
        guard !running else { return completion(.failure(RunError(description:"上一次操作还没结束"))) }
        running=true
        queue.async { [self] in
            let deadline=Date().addingTimeInterval(AutoSpaces.runTimeout)
            var removed=0
            let result: Result<Int,RunError>
            do {
                guard !ids.isEmpty,ids.count<=AutoSpaces.maxPerRun else { throw RunError(description:"数量超出上限") }
                guard let frame=Self.screenFrame(token:token) else { throw RunError(description:"找不到内置屏") }
                try driver.open()
                for id in ids {
                    guard Date()<deadline else { throw RunError(description:"超时") }
                    let before=try ordinary(on:token)
                    guard !AutoSpaces.fullScreenActive(before.all) else { throw RunError(description:AutoSpaces.Blocker.fullScreenActive.description) }
                    guard before.ids.count>1,before.ids.contains(id) else { throw RunError(description:"桌面已变化") }
                    guard before.all.first(where:{ $0.id==id })?.active != true else { throw RunError(description:"要删的桌面正在使用") }
                    guard let occupied=SpaceOccupancy.occupied(spaces:spaces) else { throw RunError(description:"读不到窗口所在桌面") }
                    guard !occupied.contains(id) else { throw RunError(description:"桌面里有窗口，不删") }
                    let buttons=try driver.spaceButtons(screen:frame)
                    guard let i=AutoSpaces.buttonIndex(of:id,ordered:before.ids,buttonCount:buttons.count) else { throw RunError(description:"调度中心里的桌面数和系统记录对不上") }
                    try driver.remove(button:buttons[i])
                    let ok=try waitFor(deadline) { AutoSpaces.verifyRemoved(id,before:before.ids,after:try ordinary(on:token).ids) }
                    guard ok else { throw RunError(description:"关闭后桌面没有按预期减少") }
                    removed+=1
                }
                result = .success(removed)
            } catch let e as RunError { result = .failure(RunError(description:e.description+(removed>0 ? "（已删 \(removed) 个）" : "")))
            } catch { result = .failure(RunError(description:"\(error)"+(removed>0 ? "（已删 \(removed) 个）" : ""))) }
            driver.close()
            DispatchQueue.main.async { self.running=false; completion(result) }
        }
    }

    /// Diagnostics: read-only dump of the Mission Control AX tree.
    func inspect(completion: @escaping (String) -> Void) {
        guard !running else { return completion("正在操作桌面，请稍后") }
        queue.async { [self] in
            var text=driver.inspect()
            let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            let dir=AppInstallation.dataDirectory(applicationSupport:support).appendingPathComponent("Diagnostics",isDirectory:true)
            let url=dir.appendingPathComponent("mission-control-ax.txt")
            do { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); try text.write(to:url,atomically:true,encoding:.utf8)
                text="已保存到 \(url.path)\n"+text } catch { text="保存文件失败：\(error)\n"+text }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Diagnostics: reversible trial. Adds one Space to `token`, then removes that same (new, empty) Space.
    func trial(token: String,completion: @escaping (String) -> Void) {
        guard let before=try? ordinary(on:token).ids else { return completion("读不到桌面") }
        add(count:1,token:token) { [self] r in
            switch r {
            case .failure(let e): completion("加桌面失败：\(e)。没有删除任何桌面。")
            case .success:
                guard let after=try? ordinary(on:token).ids,let new=after.first(where:{ !before.contains($0) }) else { return completion("已加一个桌面，但认不出是哪个，未删除；请在调度中心手动删掉最右边的空桌面。") }
                remove(ids:[new],token:token) { r2 in
                    switch r2 {
                    case .success: completion("通过：加了一个桌面，又把它删掉了，桌面数恢复为 \(before.count) 个。")
                    case .failure(let e): completion("加桌面成功，删除失败：\(e)。请在调度中心手动删掉最右边的空桌面。")
                    }
                }
            }
        }
    }
}
