// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import AppKit
import SwiftUI
import LayoutCore

struct Toast {
    struct Action { var title: String; var run: () -> Void }
    var icon: String
    var tone: Tone
    var title: String
    var detail: String?=nil
    var actions: [Action]=[]
    var duration: TimeInterval=2
}

/// Non-modal, non-activating notice in the top-right corner. One at a time; hovering keeps it open.
final class ToastCenter {
    private var panel: NSPanel?
    private var timer: Timer?
    func show(_ toast: Toast) {
        timer?.invalidate(); panel?.close()
        let p=NSPanel(contentRect:NSRect(x:0,y:0,width:360,height:80),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        p.isFloatingPanel=true; p.level = .statusBar; p.hidesOnDeactivate=false; p.isReleasedWhenClosed=false
        p.backgroundColor = .clear; p.isOpaque=false; p.hasShadow=true
        p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        let close={ [weak self,weak p] in self?.timer?.invalidate(); p?.close() }
        let view=ToastView(toast:toast,actions:toast.actions.map{ a in Toast.Action(title:a.title,run:{ close(); a.run() }) },close:close,hover:{ [weak self] inside in
            guard let self else { return }
            if inside { self.timer?.invalidate() } else { self.schedule(toast.duration,close) }
        })
        let hosting=NSHostingView(rootView:view)
        p.contentView=hosting
        p.setContentSize(hosting.fittingSize)
        if let screen=NSScreen.screens.first(where:{ $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let v=screen.visibleFrame
            p.setFrameOrigin(NSPoint(x:v.maxX-p.frame.width-12,y:v.maxY-p.frame.height-12))
        }
        p.orderFrontRegardless(); panel=p
        schedule(toast.duration,close)
    }
    private func schedule(_ duration: TimeInterval,_ close: @escaping () -> Void) {
        timer?.invalidate()
        let t=Timer(timeInterval:duration,repeats:false) { _ in close() }
        timer=t; RunLoop.main.add(t,forMode:.common)
    }
}

struct ToastView: View {
    let toast: Toast
    var actions: [Toast.Action]
    var close: () -> Void={}
    var hover: (Bool) -> Void={ _ in }
    var body: some View {
        HStack(alignment:.center,spacing:12) {
            Image(systemName:toast.icon).font(.system(size:20,weight:.semibold)).foregroundStyle(toast.tone.color).frame(width:26)
            VStack(alignment:.leading,spacing:2) {
                Text(toast.title).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                if let detail=toast.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal:false,vertical:true) }
            }
            Spacer(minLength:4)
            ForEach(Array(actions.enumerated()),id:\.offset) { index,action in
                Button(action.title,action:action.run).controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal,14).padding(.vertical,12)
        .frame(width:360)
        .background(ToastBackground())
        .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).strokeBorder(Color.primary.opacity(0.08)))
        .onHover(perform:hover)
    }
}

struct ToastBackground: View {
    var body: some View {
        if RenderMode.snapshot { Color(nsColor:.windowBackgroundColor) }
        else { WindowBackdropHUD() }
    }
}
struct WindowBackdropHUD: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v=NSVisualEffectView(); v.material = .popover; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
