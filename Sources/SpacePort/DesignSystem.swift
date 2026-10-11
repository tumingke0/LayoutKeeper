// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI

/// Set while rendering offscreen PNG snapshots: materials can't be captured, so surfaces use opaque fills.
enum RenderMode { static var snapshot=false }

enum Tone { case neutral, success, info, accent, warning, danger
    /// Yellow that stays readable on light backgrounds.
    static let amber=Color(nsColor:NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? .systemYellow : NSColor(red:0.78,green:0.55,blue:0.0,alpha:1) })
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return .green
        case .info: return .blue
        case .accent: return .purple
        case .warning: return Tone.amber
        case .danger: return .red
        }
    }
}

struct CardBackground: ViewModifier {
    var radius: CGFloat=16
    func body(content: Content) -> some View {
        if RenderMode.snapshot {
            content.background(RoundedRectangle(cornerRadius:radius,style:.continuous).fill(Color(nsColor:.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius:radius,style:.continuous).strokeBorder(Color.primary.opacity(0.07)))
                .shadow(color:.black.opacity(0.06),radius:8,y:2)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular,in:RoundedRectangle(cornerRadius:radius,style:.continuous))
        } else {
            content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:radius,style:.continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}
extension View {
    func card(radius: CGFloat=16) -> some View { modifier(CardBackground(radius:radius)) }
}

/// Window background: vibrancy in the app, opaque when rendering snapshots.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v=NSVisualEffectView(); v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .followsWindowActiveState; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
extension View {
    @ViewBuilder func windowBackdrop() -> some View {
        if RenderMode.snapshot { background(Color(nsColor:.windowBackgroundColor)) } else { background(WindowBackdrop().ignoresSafeArea()) }
    }
}

enum AppIcons {
    private static var cache: [String:NSImage]=[:]
    static func icon(_ bundleID: String) -> NSImage {
        if let cached=cache[bundleID] { return cached }
        let image: NSImage
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) { image=NSWorkspace.shared.icon(forFile:url.path) }
        else { image=NSWorkspace.shared.icon(for:.application) }
        cache[bundleID]=image; return image
    }
}
struct AppIconView: View {
    let bundleID: String; var size: CGFloat=28
    var body: some View { Image(nsImage:AppIcons.icon(bundleID)).resizable().interpolation(.high).frame(width:size,height:size) }
}

struct Pill: View {
    let text: String; var systemImage: String?=nil; var tone: Tone = .neutral
    var body: some View {
        HStack(spacing:4) {
            if let systemImage { Image(systemName:systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(tone.color)
        .padding(.horizontal,8).padding(.vertical,3)
        .background(Capsule().fill(tone.color.opacity(0.13)))
    }
}

/// Monitor-shaped tiles, one per ordinary desktop, with the saved windows drawn at their saved positions.
struct SpacesMiniMap: View {
    struct Slot: Identifiable { let id: Int; let windows: [(bundleID: String,frame: CGRect)] }
    let slots: [Slot]
    var tileWidth: CGFloat=104
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            ForEach(slots) { slot in
                VStack(spacing:5) {
                    ZStack(alignment:.topLeading) {
                        RoundedRectangle(cornerRadius:7,style:.continuous).fill(LinearGradient(colors:[Color.accentColor.opacity(0.16),Color.accentColor.opacity(0.06)],startPoint:.top,endPoint:.bottom))
                        RoundedRectangle(cornerRadius:7,style:.continuous).strokeBorder(Color.primary.opacity(0.10))
                        GeometryReader { geo in
                            ForEach(Array(slot.windows.enumerated()),id:\.offset) { _,w in
                                let r=CGRect(x:max(0,min(w.frame.minX,0.98))*geo.size.width,y:max(0,min(w.frame.minY,0.98))*geo.size.height,
                                             width:max(0.16,min(w.frame.width,1))*geo.size.width,height:max(0.2,min(w.frame.height,1))*geo.size.height)
                                RoundedRectangle(cornerRadius:3,style:.continuous).fill(Color(nsColor:.windowBackgroundColor).opacity(0.92))
                                    .overlay(RoundedRectangle(cornerRadius:3,style:.continuous).strokeBorder(Color.primary.opacity(0.12)))
                                    .overlay(AppIconView(bundleID:w.bundleID,size:min(18,max(10,min(r.width,r.height)*0.6))))
                                    .frame(width:min(r.width,geo.size.width-r.minX),height:min(r.height,geo.size.height-r.minY))
                                    .offset(x:r.minX,y:r.minY)
                            }
                        }.padding(4)
                    }.frame(width:tileWidth,height:tileWidth*0.62)
                    Text("桌面 \(slot.id)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Offscreen snapshot windows are never key/active, so AppKit draws `.borderedProminent` grey.
/// In snapshot mode only, draw an equivalent accent-filled button so PNGs match the live look.
struct SnapshotProminentStyle: ButtonStyle {
    @Environment(\.controlSize) var controlSize
    @Environment(\.isEnabled) var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let large=controlSize == .large
        configuration.label.font(large ? .body.weight(.medium) : .body).foregroundStyle(.white)
            .padding(.horizontal,large ? 14 : 10).padding(.vertical,large ? 4 : 2)
            .frame(maxWidth:nil)
            .background(RoundedRectangle(cornerRadius:large ? 8 : 6,style:.continuous).fill(Color.accentColor.opacity(isEnabled ? 1 : 0.45)))
    }
}
extension View {
    @ViewBuilder func primaryButton() -> some View {
        if RenderMode.snapshot { buttonStyle(SnapshotProminentStyle()) } else { buttonStyle(.borderedProminent) }
    }
}
