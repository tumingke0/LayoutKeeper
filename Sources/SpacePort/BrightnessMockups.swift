// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import LayoutCore
import AppKit
import SwiftUI

/// DESIGN MOCKUPS ONLY (brightness / volume). `--render-brightness-mockups <dir>`. No hardware access.

/// On-screen HUD shown when a brightness/volume key adjusts the display under the mouse.
struct BrightnessHUD: View {
    var name: String
    var percent: Double            // 0…1
    var nits: Int?=nil
    var kind: Kind = .brightness
    var note: String?=nil          // e.g. "软件调暗"
    /// true when hosted on a live NSVisualEffectView (real blur behind); false draws a translucent stand-in for mockups.
    var liveGlass=false
    enum Kind { case brightness, volume, muted }
    @Environment(\.colorScheme) private var scheme
    private var lowIcon: String { kind == .brightness ? "sun.min" : "speaker.fill" }
    private var highIcon: String { kind == .brightness ? "sun.max" : "speaker.wave.3.fill" }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:8) {
                Text(name).font(.system(size:15,weight:.semibold))
                HStack(spacing:5) {
                    Text(kind == .muted ? lk("静音") : "\(Int((percent*100).rounded()))%").foregroundStyle(Color.accentColor)
                    if let nits { Circle().frame(width:3,height:3).opacity(0.5); Text(lk("%@ 尼特", "\(nits)")) }
                    if let note { Circle().frame(width:3,height:3).opacity(0.5); Text(note) }
                }
                .font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal,9).padding(.vertical,3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength:0)
            }
            HStack(spacing:10) {
                Image(systemName:kind == .muted ? "speaker.slash.fill" : lowIcon).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary).frame(width:18)
                VStack(spacing:6) {
                    GeometryReader { g in
                        ZStack(alignment:.leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(Color.primary.opacity(kind == .muted ? 0.25 : 0.85)).frame(width:max(6,g.size.width*percent))
                        }
                    }.frame(height:6)
                    HStack(spacing:0) {
                        ForEach(0..<17) { i in
                            Circle().fill(Color.primary.opacity(Double(i)/16 <= percent ? 0.45 : 0.18)).frame(width:3,height:3)
                            if i<16 { Spacer(minLength:0) }
                        }
                    }
                }
                Image(systemName:highIcon).font(.system(size:16,weight:.medium)).foregroundStyle(.secondary).frame(width:22)
            }
        }
        .shadow(color:(scheme == .dark ? Color.black : Color.white).opacity(0.45),radius:1.5)
        .padding(.horizontal,20).padding(.vertical,16)
        .frame(width:420)
        .background(RoundedRectangle(cornerRadius:22,style:.continuous).fill(tint))
        .overlay(RoundedRectangle(cornerRadius:22,style:.continuous).strokeBorder(scheme == .dark ? Color.white.opacity(0.18) : Color.white.opacity(0.55),lineWidth:0.8))
        .overlay(RoundedRectangle(cornerRadius:22,style:.continuous).strokeBorder(Color.black.opacity(scheme == .dark ? 0.35 : 0.08),lineWidth:0.5).padding(-0.5))
        .shadow(color:.black.opacity(liveGlass ? 0 : 0.18),radius:14,y:4)
    }
    /// Low tint so the blurred desktop shows through; text stays readable thanks to the vibrancy/blur underneath.
    private var tint: Color {
        if liveGlass { return scheme == .dark ? Color.black.opacity(0.03) : Color.white.opacity(0.05) }
        return scheme == .dark ? Color(white:0.12).opacity(0.22) : Color.white.opacity(0.28)
    }
}

/// Fake desktop behind the HUD so translucency is visible in the mockup.
struct MockDesktop<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors:scheme == .dark ? [Color(red:0.10,green:0.13,blue:0.22),Color(red:0.25,green:0.12,blue:0.30)] : [Color(red:0.62,green:0.78,blue:0.95),Color(red:0.95,green:0.80,blue:0.70)],startPoint:.topLeading,endPoint:.bottomTrailing)
            VStack(spacing:14) { content }.padding(40)
        }
    }
}

/// Status-menu section mockup: one block per display.
struct BrightnessMenuMock: View {
    struct DisplayRow { var name: String; var badge: String; var badgeTone: Tone; var brightness: Double; var volume: Double?; var note: String? }
    var rows: [DisplayRow]
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            menuText(lk("显示器")).padding(.top,6)
            ForEach(Array(rows.enumerated()),id:\.offset) { i,r in
                VStack(alignment:.leading,spacing:6) {
                    HStack(spacing:6) {
                        Image(systemName:r.badge == lk("内建") ? "laptopcomputer" : "display").foregroundStyle(.secondary)
                        Text(r.name).font(.system(size:13,weight:.semibold))
                        Pill(text:r.badge,tone:r.badgeTone)
                        Spacer()
                    }
                    slider("sun.min","sun.max",r.brightness)
                    if let v=r.volume { slider("speaker.fill","speaker.wave.3.fill",v) }
                    if let note=r.note { Text(note).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                }.padding(.horizontal,12).padding(.vertical,8)
                if i<rows.count-1 { Divider().padding(.horizontal,12) }
            }
            Divider().padding(.horizontal,8).padding(.vertical,4)
            menuItem(lk("亮度键调节鼠标所在的屏幕"),check:true)
            menuItem(lk("显示器设置…"))
            Divider().padding(.horizontal,8).padding(.vertical,4)
            menuItem(lk("恢复布局")).opacity(0.55)
            menuItem(lk("保存当前布局")).opacity(0.55)
        }
        .padding(.vertical,5).frame(width:320)
        .background(RoundedRectangle(cornerRadius:10).fill(Color(nsColor:.windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color.primary.opacity(0.12)))
        .padding(20)
    }
    func slider(_ lo: String,_ hi: String,_ v: Double) -> some View {
        HStack(spacing:8) {
            Image(systemName:lo).font(.system(size:11)).foregroundStyle(.secondary).frame(width:16)
            GeometryReader { g in
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height:5)
                    Capsule().fill(Color.accentColor).frame(width:g.size.width*v,height:5)
                    Circle().fill(.white).shadow(color:.black.opacity(0.3),radius:1.5).frame(width:14,height:14).offset(x:g.size.width*v-7)
                }.frame(maxHeight:.infinity)
            }.frame(height:16)
            Image(systemName:hi).font(.system(size:13)).foregroundStyle(.secondary).frame(width:18)
            Text("\(Int(v*100))%").font(.system(size:11).monospacedDigit()).foregroundStyle(.secondary).frame(width:32,alignment:.trailing)
        }
    }
    func menuText(_ s: String) -> some View { Text(s).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,2) }
    func menuItem(_ s: String,check: Bool=false) -> some View {
        HStack(spacing:6) { Image(systemName:"checkmark").opacity(check ? 1 : 0).font(.system(size:11,weight:.semibold)); Text(s).font(.system(size:13)); Spacer() }
            .padding(.horizontal,10).frame(height:24)
    }
}

/// Placement mockup: a screen with its menu bar; the HUD sits top-centre just below it.
struct HUDPlacementMock: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment:.top) {
            LinearGradient(colors:scheme == .dark ? [Color(red:0.10,green:0.13,blue:0.22),Color(red:0.25,green:0.12,blue:0.30)] : [Color(red:0.62,green:0.78,blue:0.95),Color(red:0.95,green:0.80,blue:0.70)],startPoint:.topLeading,endPoint:.bottomTrailing)
            VStack(alignment:.leading,spacing:10) {
                ForEach(0..<6) { i in RoundedRectangle(cornerRadius:6).fill(Color.primary.opacity(0.10)).frame(width:CGFloat(380+(i%3)*120),height:22) }
            }.padding(.top,120).padding(.leading,60).frame(maxWidth:.infinity,alignment:.leading)
            VStack(spacing:0) {
                HStack(spacing:14) { Image(systemName:"apple.logo"); Text(lk("访达")).bold(); Text(lk("文件")); Text(lk("编辑")); Spacer(); Image(systemName:"rectangle.3.group"); Text(lk("周三 16:20")) }
                    .font(.system(size:12)).padding(.horizontal,14).frame(height:26).background(Color.primary.opacity(0.08))
                BrightnessHUD(name:"DELL SE2416H",percent:0.31).padding(.top,12)
                Spacer()
            }
        }.frame(width:900,height:380)
    }
}

enum BrightnessMockups {
    static func run(to dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var ok=true
        func shot<V: View>(_ n: String,_ v: V,dark: Bool) { ok=UISnapshots.render(v,to:dir.appendingPathComponent(n),dark:dark) && ok }
        let menu=BrightnessMenuMock(rows:[
            .init(name:"DELL SE2416H",badge:"DDC",badgeTone:.success,brightness:0.38,volume:nil,note:nil),
            .init(name:lk("内建显示屏"),badge:lk("内建"),badgeTone:.neutral,brightness:0.42,volume:nil,note:nil),
        ])
        let fallback=BrightnessMenuMock(rows:[
            .init(name:"LG HDR 4K",badge:lk("软件调暗"),badgeTone:.warning,brightness:0.70,volume:nil,note:lk("这台显示器不响应 DDC（或接在不支持的转接头上），改为软件调暗。")),
        ])
        for dark in [false,true] {
            let s=dark ? "dark" : "light"
            shot("01-menu-displays-\(s).png",menu,dark:dark)
            shot("02-menu-software-dimming-\(s).png",fallback,dark:dark)
            shot("03-hud-builtin-\(s).png",MockDesktop { BrightnessHUD(name:lk("内建显示屏"),percent:0.56,nits:92) },dark:dark)
            shot("04-hud-external-ddc-\(s).png",MockDesktop { BrightnessHUD(name:"DELL SE2416H",percent:0.38) },dark:dark)
            shot("05-hud-volume-\(s).png",MockDesktop { BrightnessHUD(name:lk("系统音量"),percent:0.54,kind:.volume); BrightnessHUD(name:lk("系统音量"),percent:0.54,kind:.muted) },dark:dark)
            shot("07-hud-top-placement-\(s).png",HUDPlacementMock(),dark:dark)
            shot("06-hud-software-dimming-\(s).png",MockDesktop { BrightnessHUD(name:"LG HDR 4K",percent:0.70,note:lk("软件调暗")) },dark:dark)
        }
        return ok ? 0 : 1
    }
}
