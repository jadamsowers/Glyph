// Draws Glyph's app icon: a disc that is chunky pixels on the left and a smooth vector
// curve (with Bézier anchors and handles) on the right — pixels becoming curves.
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws the icon on a 1024×1024 canvas (y-up CoreGraphics coordinates).
func drawIcon(_ ctx: CGContext) {
    // Body: macOS icon grid — 824pt squircle-ish rounded rect centred, soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x1b1640))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [rgb(0x2a1f6b), rgb(0x120d33)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // Faint pixel grid over the left half, hinting at the bitmap world.
    let cell: CGFloat = 52
    let center = CGPoint(x: 512, y: 512), radius: CGFloat = 300
    ctx.setStrokeColor(rgb(0xffffff, 0.06))
    ctx.setLineWidth(2)
    var gx = center.x - cell * 8
    while gx <= center.x { ctx.move(to: CGPoint(x: gx, y: 100)); ctx.addLine(to: CGPoint(x: gx, y: 924)); gx += cell }
    var gy = center.y - cell * 8
    while gy <= 924 { ctx.move(to: CGPoint(x: 100, y: gy)); ctx.addLine(to: CGPoint(x: center.x, y: gy)); gy += cell }
    ctx.strokePath()

    // Warm gradient used by both halves of the disc.
    let warm = CGGradient(colorsSpace: srgb, colors: [rgb(0xffb340), rgb(0xff5a6e), rgb(0xd93ba8)] as CFArray, locations: [0, 0.55, 1])!

    // Left half: the disc rasterized into chunky pixels (cell centres inside the circle).
    ctx.saveGState()
    let pixels = CGMutablePath()
    var y = center.y - cell * 6
    while y < center.y + cell * 6 {
        var x = center.x - cell * 6
        while x < center.x {
            let c = CGPoint(x: x + cell / 2, y: y + cell / 2)
            if hypot(c.x - center.x, c.y - center.y) <= radius {
                pixels.addRoundedRect(in: CGRect(x: x + 3, y: y + 3, width: cell - 6, height: cell - 6), cornerWidth: 6, cornerHeight: 6)
            }
            x += cell
        }
        y += cell
    }
    ctx.addPath(pixels)
    ctx.clip()
    ctx.drawLinearGradient(warm, start: CGPoint(x: 212, y: 812), end: CGPoint(x: 812, y: 212), options: [])
    ctx.restoreGState()

    // Right half: the same disc as a smooth vector shape.
    ctx.saveGState()
    let half = CGMutablePath()
    half.move(to: CGPoint(x: center.x, y: center.y + radius))
    half.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
    half.closeSubpath()
    ctx.addPath(half)
    ctx.clip()
    ctx.drawLinearGradient(warm, start: CGPoint(x: 212, y: 812), end: CGPoint(x: 812, y: 212), options: [])
    ctx.restoreGState()

    // The Bézier outline of the vector half: two cubic quarter-arcs with anchors and handles.
    let k: CGFloat = 0.5523 * radius
    let top = CGPoint(x: center.x, y: center.y + radius), right = CGPoint(x: center.x + radius, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y - radius)
    let outline = CGMutablePath()
    outline.move(to: top)
    outline.addCurve(to: right, control1: CGPoint(x: top.x + k, y: top.y), control2: CGPoint(x: right.x, y: right.y + k))
    outline.addCurve(to: bottom, control1: CGPoint(x: right.x, y: right.y - k), control2: CGPoint(x: bottom.x + k, y: bottom.y))
    ctx.addPath(outline)
    ctx.setStrokeColor(rgb(0xffffff))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Handles on the right anchor (the most "vector editor" detail).
    let h1 = CGPoint(x: right.x, y: right.y + k * 0.9), h2 = CGPoint(x: right.x, y: right.y - k * 0.9)
    ctx.setStrokeColor(rgb(0xffffff, 0.85))
    ctx.setLineWidth(8)
    ctx.move(to: h1); ctx.addLine(to: h2)
    ctx.strokePath()
    for h in [h1, h2] {
        ctx.setFillColor(rgb(0xffffff))
        ctx.fillEllipse(in: CGRect(x: h.x - 22, y: h.y - 22, width: 44, height: 44))
        ctx.setFillColor(rgb(0x2a1f6b))
        ctx.fillEllipse(in: CGRect(x: h.x - 11, y: h.y - 11, width: 22, height: 22))
    }
    // Anchor squares.
    for a in [top, right, bottom] {
        let r = CGRect(x: a.x - 26, y: a.y - 26, width: 52, height: 52)
        ctx.setFillColor(rgb(0xffffff))
        ctx.fill(r)
        ctx.setFillColor(rgb(0xff5a6e))
        ctx.fill(r.insetBy(dx: 12, dy: 12))
    }
    ctx.restoreGState()
}

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(base * scale), name)
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon images to \(outDir.path)")
