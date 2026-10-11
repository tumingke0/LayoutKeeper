// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
//
// Deterministic app-icon generator. Draws the LayoutKeeper mark (two stacked tiles on the left,
// one tall tile on the right — the same shape as the in-app header mark) with plain CoreGraphics
// vectors, so no SF Symbol artwork is embedded in the icon.
//
// Usage: scripts/make-icon.sh   (writes Resources/AppIcon.icns and docs/images/icon.png)
//        or: swiftc -O scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <out.iconset> [preview.png]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

/// Superellipse ("squircle") close to the macOS Big Sur+ icon shape.
func squircle(_ r: CGRect, exponent n: CGFloat = 5, steps: Int = 720) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / n)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Draws the icon on a 1024-unit canvas scaled to `px` pixels. CoreGraphics origin is bottom-left.
func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    // Standard macOS grid: 824×824 body centred on 1024, shifted up slightly to leave room for the shadow.
    let body = CGRect(x: 100, y: 110, width: 824, height: 824)
    let shape = squircle(body)

    // Soft drop shadow (only where it is visible at the size being rendered).
    ctx.saveGState()
    // Shadow offset/blur are in device pixels (not affected by the CTM), so scale them with the icon size.
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x000000, 0.28))
    ctx.addPath(shape); ctx.setFillColor(rgb(0xF2F4F8)); ctx.fillPath()
    ctx.restoreGState()

    // Background: white → cool light gray, reads well in light and dark Docks.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF), rgb(0xE6EBF2)], from: CGPoint(x: 512, y: body.maxY), to: CGPoint(x: 512, y: body.minY))
    ctx.restoreGState()
    // Hairline edge so the white tile does not dissolve on light backgrounds.
    ctx.saveGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0x000000, 0.10)); ctx.setLineWidth(max(2, 1 / k)); ctx.strokePath()
    ctx.restoreGState()

    // The mark: same proportions as the header glyph (two stacked tiles left, one tall tile right).
    let mark = CGRect(x: 512 - 280, y: 522 - 230, width: 560, height: 460)
    let gap: CGFloat = 36
    let leftW = (mark.width - gap) * 0.46
    let rightW = mark.width - gap - leftW
    let tileH = (mark.height - gap) / 2
    let radius: CGFloat = 52
    let topLeft = CGRect(x: mark.minX, y: mark.minY + tileH + gap, width: leftW, height: tileH)
    let bottomLeft = CGRect(x: mark.minX, y: mark.minY, width: leftW, height: tileH)
    let right = CGRect(x: mark.minX + leftW + gap, y: mark.minY, width: rightW, height: mark.height)

    func tile(_ r: CGRect, _ top: UInt32, _ bottom: UInt32) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 14 * k, color: rgb(0x0A3D91, 0.22))
        ctx.addPath(path); ctx.setFillColor(rgb(bottom)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        linear(ctx, [rgb(top), rgb(bottom)], from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.minY))
        ctx.restoreGState()
    }
    // Left tiles: saturated system-like blue; right tile: lighter blue (as in the header gradient).
    tile(topLeft, 0x2F8BFF, 0x0A63E0)
    tile(bottomLeft, 0x2F8BFF, 0x0A63E0)
    tile(right, 0x6BB2FF, 0x3488F5)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-icon <out.iconset> [preview-1024.png]"); exit(2) }
let set = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if args.count >= 3 { writePNG(render(px: 1024), to: URL(fileURLWithPath: args[2])) }
print("wrote \(set.path)")
