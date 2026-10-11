// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import ApplicationServices
import SwiftUI
import LayoutCore
import MacAdapters

enum GuidedMode: String, CaseIterable { case simulation="安全演示", blank="空白窗口实测" }

extension Model {
    var guidedKey: String { "\(mode.rawValue)/\(location)" }
    var guidedProfile: Profile? { guidedProfiles[guidedKey] }
    var guidedDirectory: URL? {
        if let guidedStorageOverride { return guidedStorageOverride }
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",isDirectory:true)
        return AppInstallation.layoutDirectory(bundleURL:Bundle.main.bundleURL,applicationSupport:support)
    }
    func guidedURL() throws -> URL {
        guard let directory=guidedDirectory else { throw LayoutError.unsupported }
        let name=location=="家" ? "home" : "company"
        return directory.appendingPathComponent(mode == .simulation ? "demo" : "blank",isDirectory:true).appendingPathComponent("\(name).json")
    }
    func loadGuidedProfiles() {
        refreshAuthorization(); guidedPreview=nil; guidedResults=[]; guidedBindings=guidedBindingArchive[guidedKey] ?? []
        demoSnapshot=guidedDemo.state
        do {
            let url=try guidedURL()
            if FileManager.default.fileExists(atPath:url.path) {
                let profile=try ProfileStore.load(from:url)
                guard profile.location==location else { throw LayoutError.invalidProfile }
                guidedProfiles[guidedKey]=profile
            }
            guidedMessage=guidedProfile==nil ? "当前选择\(location)。先点“保存布局”，再体验恢复。" : "已读取\(location)保存的布局。安全演示可直接预览恢复；空白窗口仅在保存它的本次会话内恢复原桌面位置。"
        } catch { guidedMessage="无法读取这份布局。可以先进行演示，再重新保存。" }
    }
    // This path always reads exactly our own single empty fixture. No other apps can enter the preview.
    func guidedBlankSnapshot(bindForSave: Bool = false) throws -> Snapshot {
        refreshAuthorization()
        guard trusted else { throw LayoutError.permissionRequired }
        guard let fixture=fixtures.first, fixture.isVisible, let id=UInt32(exactly:fixture.windowNumber) else { throw LayoutError.readbackUnavailable }
        var s=try windows.scan(onlyPID:getpid())
        s.windows=s.windows.filter{$0.token=="\(getpid()):\(id)" && $0.selector.title=="LayoutKeeper Fixture 1"}
        guard s.windows.count==1, s.windows[0].ordinary, !s.windows[0].fullScreen, !s.windows[0].minimized,
              s.windows[0].spaceIDs.count==1, let source=s.spaces.first(where:{$0.id==s.windows[0].spaceIDs[0] && $0.kind == .ordinary}),
              let display=s.displays.first(where:{$0.token==source.displayToken}) else { throw LayoutError.readbackUnavailable }
        if bindForSave {
            guidedBindings=[DesktopBinding(label:"空白演示",role:display.role,spaceID:source.id,snapshot:s)]
        }
        return s
    }
    func guidedSave() {
        guidedPreview=nil; guidedResults=[]
        let priorBindings=guidedBindings
        do {
            let profile: Profile
            if mode == .simulation { profile=try guidedDemo.capture(location:location) }
            else {
                let s=try guidedBlankSnapshot(bindForSave:true)
                let (captured,issues)=try Planner.capture(location:location,snapshot:s,bindings:guidedBindings)
                guard captured.windows.count==1,issues.isEmpty else { throw LayoutError.readbackUnavailable }
                profile=captured
            }
            let url=try guidedURL()
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try ProfileStore.save(profile,to:url)
            guidedProfiles[guidedKey]=profile; demoSnapshot=guidedDemo.state
            if mode == .blank { guidedBindingArchive[guidedKey]=guidedBindings }
            guidedMessage=mode == .simulation ? "已保存\(location)的演示布局。现在点“模拟打乱”，看看恢复效果。" : "已保存\(location)的空白窗口位置。用鼠标移动或调整它，再点“预览恢复”。"
        } catch {
            guidedBindings=priorBindings
            guidedMessage=mode == .blank && !trusted ? accessState.guidance : "保存没有完成。请打开空白演示窗口并保持普通窗口状态，或查看高级页的详细原因。"
            message="快速保存：\(error)"
        }
    }
    func guidedScatter() {
        guard mode == .simulation else { return }
        guidedDemo.scatter(); demoSnapshot=guidedDemo.state; guidedPreview=nil; guidedResults=[]
        guidedMessage="演示窗口已打乱。点“预览恢复”，查看它们将回到哪里。"
    }
    func guidedMakePreview() {
        guidedResults=[]; guidedPreview=nil
        guard let profile=guidedProfile, !profile.windows.isEmpty else { guidedMessage="这个地点还没有保存布局，请先点“保存布局”。"; return }
        do {
            if mode == .simulation { guidedPreview=try guidedDemo.plan(profile:profile) }
            else {
                let s=try guidedBlankSnapshot()
                guidedPreview=try Planner.plan(profile:profile,snapshot:s,bindings:guidedBindings,canMoveSpaces:false)
            }
            guidedMessage="请先查看预览，再决定是否恢复。"
        } catch { guidedMessage="无法生成预览。请保持空白演示窗口打开；具体读取错误已记录。"; message="快速预览：\(error)" }
    }
    func guidedRestore() {
        guard !restoring, let plan=guidedPreview else { return }
        guard plan.entries.contains(where:{$0.status == .ready}) else { guidedMessage="没有可恢复项目；未移动任何窗口。"; return }
        restoring=true
        defer { restoring=false; guidedPreview=nil }
        if mode == .simulation {
            guidedResults=Restorer.execute(plan,windows:guidedDemo,spaces:guidedDemo,approved:true)
            demoSnapshot=guidedDemo.state
        } else {
            guard let fixture=fixtures.first,
                  plan.entries.allSatisfy({$0.window == nil || ($0.window!.token=="\(getpid()):\(fixture.windowNumber)" && $0.saved.selector.title=="LayoutKeeper Fixture 1")}) else { guidedMessage="窗口身份已改变，请重新预览。"; return }
            let alert=NSAlert(); alert.messageText="只恢复这个空白演示窗口？"
            alert.informativeText="只改变 LayoutKeeper 新建空白窗口的位置和大小，完成后读取实际结果。不会移动你的软件窗口。失败时可能留下部分大小变化，请检查结果。"
            alert.addButton(withTitle:"恢复空白窗口"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { guidedMessage="已取消，没有执行恢复。"; return }
            windows.writesApproved=true; defer { windows.writesApproved=false }
            guidedResults=Restorer.execute(plan,windows:windows,spaces:spaces,approved:true,polls:20,pause:{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.15))})
        }
        let passed=guidedResults.filter{$0.outcome == .verified}.count
        guidedMessage=passed==guidedResults.count && passed>0 ? (mode == .simulation ? "演示恢复成功：\(passed) 个模拟窗口已回到保存的位置。你的软件窗口没有变化。" : "空白窗口恢复成功：位置、大小和所在桌面都已读取确认。") : "\(passed) 项恢复成功，其余项目未通过验证。请查看下方结果。"
    }
    func usableTitle(_ title: String) -> String { title=="LayoutKeeper Fixture 1" ? "空白演示窗口" : title }
    func usableStatus(_ status: PlanStatus) -> String {
        switch status { case .ready: return "可以恢复"; case .blocked: return "暂不能恢复"; case .skipped: return "已跳过" }
    }
    func usableReason(_ entry: PlanEntry) -> String {
        if entry.status == .ready { return mode == .simulation ? "回到\(location)保存时的位置和大小（模拟）" : "回到\(location)保存的位置和大小，只影响空白窗口" }
        if entry.reason.contains("跨桌面") { return "窗口已在另一个桌面；此版本不会自动把它移回来。请先手动放回原桌面。" }
        if entry.reason.contains("绑定") { return "这份布局的原桌面在当前会话无法确认。请重新保存当前空白窗口布局。" }
        if entry.reason.contains("屏幕") { return "保存时使用的屏幕当前没有连接。" }
        return "当前窗口不符合安全恢复条件。高级页可查看详细原因。"
    }
}

struct DemoScreen: View {
    let windows: [ObservedWindow]
    var body: some View {
        GeometryReader { geometry in
            let scale=min(geometry.size.width/1000,geometry.size.height/640)
            ZStack(alignment:.topLeading) {
                RoundedRectangle(cornerRadius:12).fill(Color.blue.opacity(0.08))
                ForEach(Array(windows.enumerated()),id:\.offset) { index,window in
                    VStack(alignment:.leading,spacing:8) {
                        HStack { Circle().fill(.red.opacity(0.65)).frame(width:7,height:7); Circle().fill(.yellow.opacity(0.65)).frame(width:7,height:7); Circle().fill(.green.opacity(0.65)).frame(width:7,height:7); Spacer() }
                        Text(window.selector.title).font(.headline)
                        RoundedRectangle(cornerRadius:3).fill(Color.secondary.opacity(0.12)).frame(height:7)
                        RoundedRectangle(cornerRadius:3).fill(Color.secondary.opacity(0.08)).frame(height:7)
                        Spacer()
                        Text("模拟窗口").font(.caption).foregroundStyle(Color.black.opacity(0.5))
                    }.foregroundStyle(Color.black.opacity(0.8)).padding(12).frame(width:window.frame.width*scale,height:window.frame.height*scale)
                        .background(index==0 ? Color.white : Color(red:0.93,green:0.98,blue:0.96)).clipShape(RoundedRectangle(cornerRadius:9))
                        .overlay(RoundedRectangle(cornerRadius:9).stroke(Color.secondary.opacity(0.22))).shadow(color:.black.opacity(0.09),radius:5,y:3)
                        .offset(x:window.frame.x*scale,y:window.frame.y*scale)
                }
            }.frame(width:1000*scale,height:640*scale).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(height:250).accessibilityElement(children:.ignore).accessibilityLabel("安全演示屏幕，包含编辑器与聊天两个模拟窗口")
    }
}

struct AdvancedContent: View {
    @ObservedObject var model: Model
    @State var showingPreview=false
    @State var showingFixtureSpaces=false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:18) {
                        Text("安全演示与空白窗口测试").font(.headline)
                        Text("只影响应用内的模拟图或 LayoutKeeper 自己新建的空白窗口，用来体验和排查；日常使用请用主窗口的「保存布局」「恢复布局」。")
                            .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        HStack {
                            Text("地点").bold()
                            Picker("地点",selection:$model.location) { Text("家").tag("家"); Text("公司").tag("公司") }.pickerStyle(.segmented).labelsHidden().frame(width:200)
                            Spacer()
                            Picker("体验方式",selection:$model.mode) { ForEach(GuidedMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width:300)
                        }
                        HStack(spacing:16) {
                            VStack(alignment:.leading) {
                                Text(model.guidedProfile==nil ? "\(model.location)还没有保存布局" : "\(model.location)已保存 \(model.guidedProfile!.windows.count) 个\(model.mode == .simulation ? "模拟" : "空白")窗口").font(.headline)
                                Text("家、公司分别保存；再次保存会覆盖当前布局并保留上一版。演示和空白实测配置互不混用。").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("保存布局") { model.guidedSave() }.buttonStyle(.borderedProminent)
                                .disabled(model.mode == .blank && (!model.trusted || model.fixtures.isEmpty))
                            if model.mode == .simulation { Button("模拟打乱") { withAnimation(.easeInOut(duration:0.3)) { model.guidedScatter() } }.disabled(model.guidedProfile==nil) }
                            Button("预览恢复") { model.guidedMakePreview(); showingPreview=model.guidedPreview != nil }.buttonStyle(.bordered)
                                .disabled(model.guidedProfile==nil || (model.mode == .blank && (!model.trusted || model.fixtures.isEmpty)))
                        }
                        Text(model.guidedMessage).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.blue.opacity(0.06)).cornerRadius(8)
                        GroupBox {
                            VStack(alignment:.leading,spacing:12) {
                                if model.mode == .simulation {
                                    HStack { Label("安全演示：只改变下方的模拟窗口",systemImage:"shield.checkered"); Spacer(); Text("无需权限").foregroundStyle(.green) }
                                    DemoScreen(windows:model.demoSnapshot.windows).frame(maxWidth:600).frame(maxWidth:.infinity)
                                    Text("保存 → 模拟打乱 → 预览并恢复").foregroundStyle(.secondary)
                                } else {
                                    Label("只影响 LayoutKeeper 新建的一个空白窗口",systemImage:"rectangle.badge.checkmark").font(.headline)
                                    Text("打开空白窗口后保存，用鼠标移动或调整它，再预览恢复。屏幕与桌面由应用自动识别。不会处理其他软件窗口。")
                                    Button(model.fixtures.isEmpty ? "打开空白演示窗口" : "显示空白演示窗口") {
                                        model.createFixtures(); model.fixtures.first?.makeKeyAndOrderFront(nil)
                                    }
                                    if model.guidedProfile != nil && model.guidedBindings.isEmpty {
                                        Text("已读取以前的空白窗口布局，但无法安全确认它的原桌面。请先保存这次新建的空白窗口，再测试恢复。")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    if !model.trusted {
                                        Text(model.accessState.guidance)
                                            .font(.callout).foregroundStyle(.orange)
                                        Button("打开系统设置") { model.openControlSettings() }
                                    }
                                }
                            }.padding(8)
                        }
                        GroupBox("受控跨桌面验收 · 仅空白窗口") {
                            VStack(alignment:.leading,spacing:8) {
                                Text("只测试上方创建的空白窗口，目标回读后立即返回原桌面。真实窗口请用「诊断」里的一键自检。")
                                Button("预览空白窗口桌面往返") { model.prepareFixtureSpacePreview(); showingFixtureSpaces=true }
                                    .disabled(!model.trusted || model.fixtures.isEmpty || !model.crossSpaceEnabled)
                                Text(model.fixtureSpaceMessage).font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                        ForEach(Array(model.guidedResults.enumerated()),id:\.offset) { _,result in
                            Label("\(model.usableTitle(result.title))：\(result.outcome == .verified ? "恢复并验证成功" : "未通过验证")",systemImage:result.outcome == .verified ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(result.outcome == .verified ? .green : .orange)
                        }
                    }
        }.disabled(model.restoring)
            .onChange(of:model.location) { model.loadGuidedProfiles() }
            .onChange(of:model.mode) { model.loadGuidedProfiles() }
            .sheet(isPresented:$showingPreview) { previewSheet }
            .sheet(isPresented:$showingFixtureSpaces) { FixtureSpaceSheet(model:model) }
    }
    private var previewSheet: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("恢复到\(model.location)保存的布局").font(.title2.bold())
            Text(model.mode == .simulation ? "这是模拟预览，恢复只影响应用内的演示图。" : "仅恢复新建的空白演示窗口，不操作其他软件。")
            if let plan=model.guidedPreview {
                ForEach(Array(plan.entries.enumerated()),id:\.offset) { _,entry in
                    VStack(alignment:.leading,spacing:4) {
                        Text("\(model.usableTitle(entry.saved.selector.title)) · \(model.usableStatus(entry.status))").bold()
                        Text(model.usableReason(entry)).font(.callout).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary).cornerRadius(8)
                }
                HStack {
                    Spacer()
                    Button(model.mode == .simulation ? "恢复演示布局" : "确认恢复空白窗口") { model.guidedRestore(); showingPreview=false }
                        .buttonStyle(.borderedProminent).disabled(!plan.entries.contains{$0.status == .ready})
                }
            } else { Text("屏幕或桌面状态已改变，请关闭后重新预览。") }
            Button("取消") { showingPreview=false }
        }.padding(24).frame(width:540)
    }
}
