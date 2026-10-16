#!/usr/bin/env swift
// Editable, resolution-independent artwork for the Sys Cleaner macOS app icon.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red / 255, green / 255, blue / 255, alpha])!
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}

func drawIcon(in context: CGContext, size: Int) {
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // Transparent corners let macOS display the icon naturally in the Dock.
    let tile = CGMutablePath()
    tile.move(to: CGPoint(x: 262, y: 48))
    tile.addLine(to: CGPoint(x: 762, y: 48))
    tile.addArc(center: CGPoint(x: 762, y: 262), radius: 214,
                startAngle: -.pi / 2, endAngle: 0, clockwise: false)
    tile.addLine(to: CGPoint(x: 976, y: 762))
    tile.addArc(center: CGPoint(x: 762, y: 762), radius: 214,
                startAngle: 0, endAngle: .pi / 2, clockwise: false)
    tile.addLine(to: CGPoint(x: 262, y: 976))
    tile.addArc(center: CGPoint(x: 262, y: 762), radius: 214,
                startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    tile.addLine(to: CGPoint(x: 48, y: 262))
    tile.addArc(center: CGPoint(x: 262, y: 262), radius: 214,
                startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    tile.closeSubpath()
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient([color(24, 62, 103), color(8, 27, 54)]),
        start: CGPoint(x: 170, y: 930), end: CGPoint(x: 890, y: 100), options: [])
    context.restoreGState()

    // The single broad sweep stays legible at 16 px and suggests removing clutter.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.move(to: CGPoint(x: 320, y: 348))
    context.addCurve(to: CGPoint(x: 723, y: 690),
                     control1: CGPoint(x: 445, y: 430), control2: CGPoint(x: 600, y: 573))
    context.setStrokeColor(color(40, 174, 215, 0.26))
    context.setLineWidth(154)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()

    // An open disk-space ring forms the primary silhouette.
    let ring = CGMutablePath()
    ring.addArc(center: CGPoint(x: 512, y: 512), radius: 266,
                startAngle: .pi / 180 * 43, endAngle: .pi / 180 * 317,
                clockwise: false)
    let thickRing = ring.copy(strokingWithWidth: 108, lineCap: .round,
                              lineJoin: .round, miterLimit: 10)
    context.saveGState()
    context.addPath(thickRing)
    context.clip()
    context.drawLinearGradient(
        gradient([color(108, 239, 220), color(34, 181, 220), color(33, 113, 194)]),
        start: CGPoint(x: 250, y: 810), end: CGPoint(x: 805, y: 220), options: [])
    context.restoreGState()

    // The short bright mark is the clean end of the sweep, with no fine detail.
    context.move(to: CGPoint(x: 428, y: 438))
    context.addCurve(to: CGPoint(x: 650, y: 616),
                     control1: CGPoint(x: 505, y: 488), control2: CGPoint(x: 585, y: 570))
    context.setStrokeColor(color(219, 254, 249))
    context.setLineWidth(74)
    context.setLineCap(.round)
    context.strokePath()
}

func writePNG(size: Int, filename: String) throws {
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
        throw NSError(domain: "SysCleanerIcon", code: 1)
    }
    drawIcon(in: context, size: size)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            iconSet.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "SysCleanerIcon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SysCleanerIcon", code: 3)
    }
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try writePNG(size: size, filename: "icon-\(size).png")
}
print("Generated AppIcon images in \(iconSet.path)")
