// Renders the GUD Display app icon at every macOS size into the asset catalog.
// Run: swift scripts/make_icon.swift
//
// Design: a display whose screen dissolves into pixels at the right edge
// (GUD streams damage rects), fed by a USB trident plugged into it,
// on a dark indigo squircle.

import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: colors as CFArray, locations: locations)!
}

func draw(into ctx: CGContext, size: Int) {
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)

    // Background squircle (Apple template: 824pt content on 1024 canvas).
    let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                    cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(bg)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x3B2A8C), color(0x191436), color(0x0B0A1E)], [0, 0.62, 1]),
        start: CGPoint(x: 250, y: 924), end: CGPoint(x: 780, y: 100), options: []
    )

    // Faint pixel grid across the background.
    ctx.setStrokeColor(color(0xFFFFFF, 0.035))
    ctx.setLineWidth(2)
    for i in stride(from: 100, through: 924, by: 68) {
        ctx.move(to: CGPoint(x: CGFloat(i), y: 100))
        ctx.addLine(to: CGPoint(x: CGFloat(i), y: 924))
        ctx.move(to: CGPoint(x: 100, y: CGFloat(i)))
        ctx.addLine(to: CGPoint(x: 924, y: CGFloat(i)))
    }
    ctx.strokePath()

    // Screen: vibrant gradient panel, dissolving into pixels on the right.
    let screenRect = CGRect(x: 202, y: 400, width: 620, height: 396)
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 34, cornerHeight: 34, transform: nil)

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x22D3EE), color(0x6366F1), color(0xD946EF)], [0, 0.55, 1]),
        start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
        end: CGPoint(x: screenRect.maxX, y: screenRect.minY), options: []
    )

    // Dissolve: carve background-colored cells out of the right edge,
    // deterministic checker-ish falloff.
    let cell: CGFloat = 44
    let cols = 5
    var seed: UInt64 = 0x67756421 // "gud!"
    func nextBit(_ threshold: UInt64) -> Bool {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (seed >> 33) % 100 < threshold
    }
    for col in 0..<cols {
        let x = screenRect.maxX - CGFloat(cols - col) * cell
        let dropChance = [15, 30, 50, 72, 90].map(UInt64.init)[col]
        var y = screenRect.minY
        while y < screenRect.maxY {
            if nextBit(dropChance) {
                ctx.setFillColor(color(0x14112E))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell).insetBy(dx: 1.5, dy: 1.5))
            }
            y += cell
        }
    }

    // Glass highlight across the top of the screen.
    ctx.drawLinearGradient(
        gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0.0)], [0, 1]),
        start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
        end: CGPoint(x: screenRect.minX, y: screenRect.maxY - 150), options: []
    )
    ctx.restoreGState()

    // Screen bezel.
    ctx.addPath(screenPath)
    ctx.setStrokeColor(color(0xF4F4F8, 0.95))
    ctx.setLineWidth(16)
    ctx.strokePath()

    // USB trident: stem plugs into the display, terminals below.
    ctx.setStrokeColor(color(0xF4F4F8, 0.95))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let stemX: CGFloat = 512
    // Stem from bottom up into the screen.
    ctx.move(to: CGPoint(x: stemX, y: 172))
    ctx.addLine(to: CGPoint(x: stemX, y: 400))
    ctx.strokePath()

    // Left branch -> circle terminal.
    ctx.move(to: CGPoint(x: stemX, y: 236))
    ctx.addCurve(to: CGPoint(x: 380, y: 300),
                 control1: CGPoint(x: stemX, y: 282), control2: CGPoint(x: 420, y: 272))
    ctx.strokePath()
    ctx.setFillColor(color(0xF4F4F8, 0.95))
    ctx.fillEllipse(in: CGRect(x: 380 - 28, y: 300 - 6, width: 56, height: 56))

    // Right branch -> square terminal.
    ctx.move(to: CGPoint(x: stemX, y: 292))
    ctx.addCurve(to: CGPoint(x: 640, y: 316),
                 control1: CGPoint(x: stemX, y: 326), control2: CGPoint(x: 600, y: 310))
    ctx.strokePath()
    ctx.fill(CGRect(x: 640 - 26, y: 306, width: 52, height: 52))

    // Stem base: connector nub.
    ctx.fill(CGRect(x: stemX - 34, y: 132, width: 68, height: 46))
}

func render(size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(into: ctx, size: size)
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let iconsetDir = URL(fileURLWithPath: "Sources/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let entries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
var images: [[String: String]] = []
for (points, scale) in entries {
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    render(size: points * scale, to: iconsetDir.appendingPathComponent(filename))
    images.append([
        "filename": filename,
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(points)x\(points)",
    ])
}

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconsetDir.appendingPathComponent("Contents.json"))

print("Wrote \(entries.count) icons to \(iconsetDir.path)")
