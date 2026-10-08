// Generates sample images for manual runs: swift scripts/make-samples.swift samples
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "samples")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func save(_ name: String, width: Int, height: Int, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    let url = dir.appendingPathComponent(name)
    let type = name.hasSuffix(".jpg") ? UTType.jpeg : UTType.png
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print(url.path)
}

func drawLogo(_ ctx: CGContext) {
    ctx.setFillColor(color(0.10, 0.20, 0.55)); ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 360, height: 360))
    ctx.setFillColor(color(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: 60, y: 60, width: 280, height: 280))
    ctx.setFillColor(color(0.95, 0.65, 0.10))
    ctx.move(to: CGPoint(x: 200, y: 300)); ctx.addLine(to: CGPoint(x: 290, y: 140)); ctx.addLine(to: CGPoint(x: 110, y: 140))
    ctx.closePath(); ctx.fillPath()
    ctx.setFillColor(color(0.85, 0.15, 0.20)); ctx.fill(CGRect(x: 120, y: 100, width: 160, height: 24))
}

// Flat logo on a transparent background.
save("logo.png", width: 400, height: 400, drawLogo)
// Same logo as a JPEG on white: compression noise, no transparency.
save("logo.jpg", width: 400, height: 400) { ctx in
    ctx.setFillColor(color(1, 1, 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    drawLogo(ctx)
}
// Photo-like: radial gradient with translucent blobs.
save("photo.png", width: 400, height: 300) { ctx in
    let g = CGGradient(colorsSpace: srgb, colors: [color(0.95, 0.80, 0.40), color(0.20, 0.35, 0.70), color(0.05, 0.05, 0.15)] as CFArray,
                       locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: 280, y: 200), startRadius: 0, endCenter: CGPoint(x: 200, y: 150),
                           endRadius: 260, options: [.drawsAfterEndLocation])
    for i in 0..<12 {
        ctx.setFillColor(color(CGFloat(i % 3) * 0.4, 0.6, CGFloat(i % 4) * 0.25, 0.35))
        ctx.fillEllipse(in: CGRect(x: 20 + i * 30, y: 30 + (i * 53) % 200, width: 60, height: 60))
    }
}
