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

func fillEllipse(_ context: CGContext, _ rect: CGRect, _ fill: CGColor) {
    context.setFillColor(fill)
    context.fillEllipse(in: rect)
}

func stroke(_ context: CGContext, from start: CGPoint, to end: CGPoint,
            width: CGFloat, color: CGColor) {
    context.move(to: start)
    context.addLine(to: end)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.strokePath()
}

func drawIcon(in context: CGContext, size: Int, variant: String) {
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
    let backgrounds: [String: (CGColor, CGColor)] = [
        "orbit": (color(24, 62, 103), color(8, 27, 54)),
        "sweep": (color(69, 54, 128), color(19, 31, 78)),
        "disk": (color(25, 80, 91), color(6, 36, 53)),
        "layers": (color(22, 86, 92), color(7, 42, 61)),
        "shield": (color(45, 69, 136), color(16, 29, 80)),
        "spark": (color(83, 47, 110), color(31, 24, 73))
    ]
    let background = backgrounds[variant]!
    context.drawLinearGradient(
        gradient([background.0, background.1]),
        start: CGPoint(x: 170, y: 930), end: CGPoint(x: 890, y: 100),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    switch variant {
    case "orbit":
        // Original open storage ring and broad cleanup stroke.
        context.move(to: CGPoint(x: 320, y: 348))
        context.addCurve(to: CGPoint(x: 723, y: 690),
                         control1: CGPoint(x: 445, y: 430), control2: CGPoint(x: 600, y: 573))
        context.setStrokeColor(color(40, 174, 215, 0.26))
        context.setLineWidth(154)
        context.setLineCap(.round)
        context.strokePath()
        let ring = CGMutablePath()
        ring.addArc(center: CGPoint(x: 512, y: 512), radius: 266,
                    startAngle: .pi / 180 * 43, endAngle: .pi / 180 * 317,
                    clockwise: false)
        context.saveGState()
        context.addPath(ring.copy(strokingWithWidth: 108, lineCap: .round,
                                  lineJoin: .round, miterLimit: 10))
        context.clip()
        context.drawLinearGradient(
            gradient([color(108, 239, 220), color(34, 181, 220), color(33, 113, 194)]),
            start: CGPoint(x: 250, y: 810), end: CGPoint(x: 805, y: 220), options: [])
        context.restoreGState()
        context.move(to: CGPoint(x: 428, y: 438))
        context.addCurve(to: CGPoint(x: 650, y: 616),
                         control1: CGPoint(x: 505, y: 488), control2: CGPoint(x: 585, y: 570))
        context.setStrokeColor(color(219, 254, 249))
        context.setLineWidth(74)
        context.setLineCap(.round)
        context.strokePath()
    case "sweep":
        // Three clear ribbons form a fast cleaning motion.
        for (offset, shade) in [(-135, color(101, 128, 244)),
                                (0, color(102, 223, 233)),
                                (135, color(216, 246, 255))] {
            let delta = CGFloat(offset)
            context.move(to: CGPoint(x: 288, y: 358 + delta))
            context.addCurve(to: CGPoint(x: 735, y: 635 + delta),
                             control1: CGPoint(x: 407, y: 590 + delta),
                             control2: CGPoint(x: 606, y: 400 + delta))
            context.setStrokeColor(shade)
            context.setLineWidth(85)
            context.setLineCap(.round)
            context.strokePath()
        }
    case "disk":
        // A solid disk and a separated capacity sector.
        fillEllipse(context, CGRect(x: 206, y: 206, width: 612, height: 612), color(88, 227, 197))
        fillEllipse(context, CGRect(x: 306, y: 306, width: 412, height: 412), color(10, 52, 69))
        let sector = CGMutablePath()
        sector.move(to: CGPoint(x: 512, y: 512))
        sector.addLine(to: CGPoint(x: 512, y: 830))
        sector.addArc(center: CGPoint(x: 512, y: 512), radius: 318,
                      startAngle: .pi / 2, endAngle: .pi / 180 * 11, clockwise: true)
        sector.closeSubpath()
        context.setFillColor(color(177, 250, 130))
        context.addPath(sector)
        context.fillPath()
        fillEllipse(context, CGRect(x: 345, y: 345, width: 334, height: 334), color(10, 52, 69))
        stroke(context, from: CGPoint(x: 512, y: 512), to: CGPoint(x: 659, y: 512),
               width: 56, color: color(214, 255, 240))
    case "layers":
        // Stacked storage shelves, with one clear row.
        for (y, shade) in [(650.0, color(90, 222, 217)),
                           (462.0, color(53, 194, 202)),
                           (274.0, color(31, 146, 188))] {
            let shelf = CGPath(roundedRect: CGRect(x: 216, y: y, width: 592, height: 128),
                               cornerWidth: 60, cornerHeight: 60, transform: nil)
            context.setFillColor(shade)
            context.addPath(shelf)
            context.fillPath()
            fillEllipse(context, CGRect(x: 268, y: y + 45, width: 38, height: 38), color(8, 62, 79))
        }
        stroke(context, from: CGPoint(x: 421, y: 338), to: CGPoint(x: 723, y: 714),
               width: 62, color: color(226, 255, 242))
    case "shield":
        // Safety-led mark for reviewed cleanup.
        let shield = CGMutablePath()
        shield.move(to: CGPoint(x: 512, y: 832))
        shield.addCurve(to: CGPoint(x: 220, y: 709),
                        control1: CGPoint(x: 400, y: 782), control2: CGPoint(x: 291, y: 744))
        shield.addLine(to: CGPoint(x: 254, y: 420))
        shield.addCurve(to: CGPoint(x: 512, y: 183),
                        control1: CGPoint(x: 267, y: 312), control2: CGPoint(x: 381, y: 221))
        shield.addCurve(to: CGPoint(x: 770, y: 420),
                        control1: CGPoint(x: 643, y: 221), control2: CGPoint(x: 757, y: 312))
        shield.addLine(to: CGPoint(x: 804, y: 709))
        shield.addCurve(to: CGPoint(x: 512, y: 832),
                        control1: CGPoint(x: 733, y: 744), control2: CGPoint(x: 624, y: 782))
        shield.closeSubpath()
        context.addPath(shield)
        context.setFillColor(color(80, 168, 238))
        context.fillPath()
        stroke(context, from: CGPoint(x: 358, y: 513), to: CGPoint(x: 469, y: 399),
               width: 82, color: color(232, 255, 251))
        stroke(context, from: CGPoint(x: 469, y: 399), to: CGPoint(x: 684, y: 630),
               width: 82, color: color(232, 255, 251))
    case "spark":
        // A four-point glint sits in an open orbit.
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: 512, y: 512), radius: 283,
                   startAngle: .pi / 180 * 125, endAngle: .pi / 180 * 52,
                   clockwise: false)
        context.addPath(arc)
        context.setLineWidth(88)
        context.setLineCap(.round)
        context.setStrokeColor(color(232, 122, 209))
        context.strokePath()
        let star = CGMutablePath()
        star.move(to: CGPoint(x: 512, y: 743))
        star.addQuadCurve(to: CGPoint(x: 743, y: 512), control: CGPoint(x: 545, y: 545))
        star.addQuadCurve(to: CGPoint(x: 512, y: 281), control: CGPoint(x: 545, y: 479))
        star.addQuadCurve(to: CGPoint(x: 281, y: 512), control: CGPoint(x: 479, y: 479))
        star.addQuadCurve(to: CGPoint(x: 512, y: 743), control: CGPoint(x: 479, y: 545))
        star.closeSubpath()
        context.addPath(star)
        context.setFillColor(color(255, 235, 246))
        context.fillPath()
    default: break
    }
}

func writePNG(size: Int, variant: String, to url: URL) throws {
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
        throw NSError(domain: "SysCleanerIcon", code: 1)
    }
    drawIcon(in: context, size: size, variant: variant)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "SysCleanerIcon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "SysCleanerIcon", code: 3)
    }
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try writePNG(size: size, variant: "orbit", to: iconSet.appendingPathComponent("icon-\(size).png"))
}
for variant in ["orbit", "sweep", "disk", "layers", "shield", "spark"] {
    let name = variant.prefix(1).uppercased() + variant.dropFirst()
    let set = root.appendingPathComponent("App/Assets.xcassets/Logo-\(name).imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for size in [512, 1024] {
        try writePNG(size: size, variant: variant, to: set.appendingPathComponent("logo-\(size).png"))
    }
    let contents = """
    {
      "images" : [
        { "filename" : "logo-512.png", "idiom" : "mac", "scale" : "1x" },
        { "filename" : "logo-1024.png", "idiom" : "mac", "scale" : "2x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
print("Generated AppIcon and six selectable logos")
