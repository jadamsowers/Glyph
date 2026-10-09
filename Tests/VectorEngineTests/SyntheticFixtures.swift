import CoreGraphics
import CoreText
import Foundation
@testable import VectorEngine

/// Synthetic stand-ins for real-world regression images (no personal images in the repo).
enum SyntheticFixtures {
    static func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// A 62-px app-icon layout like the one that regressed: three flat rounded rects at integer
    /// coordinates (hard axis-aligned edges, anti-aliased only at the small corners) on
    /// transparency, and an anti-aliased white arrow.
    static func smallIcon() -> Bitmap {
        Bitmap.render(width: 62, height: 62) { ctx in
            for (r, c) in [(CGRect(x: 3, y: 3, width: 25, height: 56), color(0.33, 0.33, 0.38)),
                           (CGRect(x: 32, y: 3, width: 27, height: 27), color(0.85, 0.76, 0.53)),
                           (CGRect(x: 32, y: 33, width: 27, height: 26), color(0.55, 0.55, 0.62))] {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.setFillColor(c); ctx.fillPath()
            }
            let arrow = [CGPoint(x: 38, y: 24), CGPoint(x: 49, y: 13), CGPoint(x: 44, y: 13), CGPoint(x: 44, y: 10), CGPoint(x: 53, y: 10),
                         CGPoint(x: 53, y: 19), CGPoint(x: 50, y: 19), CGPoint(x: 50, y: 15), CGPoint(x: 40, y: 26)]
            ctx.addLines(between: arrow); ctx.closePath()
            ctx.setFillColor(color(1, 1, 1)); ctx.fillPath()
        }
    }

    /// A dark settings-panel screenshot: subtle panels a few ΔE off the background, divider lines,
    /// anti-aliased text, popup-button circles, a slider and a row of small color swatches.
    static func uiScreenshot() -> Bitmap {
        let w = 400, h = 560
        return Bitmap.render(width: w, height: h, flipped: false) { ctx in
            func y(_ top: Double) -> Double { Double(h) - top }   // lay out top-down in a y-up context
            ctx.setFillColor(color(0.12, 0.12, 0.12)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            func panel(_ top: Double, _ height: Double) {
                ctx.addPath(CGPath(roundedRect: CGRect(x: 10, y: y(top + height), width: 380, height: height), cornerWidth: 10, cornerHeight: 10, transform: nil))
                ctx.setFillColor(color(0.165, 0.165, 0.17)); ctx.fillPath()
            }
            func text(_ s: String, _ x: Double, _ top: Double, size: Double = 15, bold: Bool = false, gray: Double = 0.92) {
                let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
                let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color(gray, gray, gray)] as CFDictionary
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs))
                ctx.textPosition = CGPoint(x: x, y: y(top + size))
                CTLineDraw(line, ctx)
            }
            text("Detected", 20, 12, size: 16, bold: true)
            panel(40, 100)
            text("Photo", 60, 58, size: 17, bold: true)
            text("16 colors", 290, 58, gray: 0.6)
            let swatches = [(0.1, 0.18, 0.45), (1, 1, 1), (0.7, 0.13, 0.17), (0.3, 0.5, 0.85), (0.6, 0.6, 0.6), (0.55, 0.2, 0.3),
                            (0.8, 0.82, 0.88), (0.2, 0.3, 0.5), (0.6, 0.66, 0.75), (0.75, 0.55, 0.6), (0.35, 0.2, 0.35), (0.2, 0.35, 0.65)]
            for (i, c) in swatches.enumerated() {
                ctx.addPath(CGPath(roundedRect: CGRect(x: 22 + Double(i) * 30, y: y(122), width: 24, height: 26), cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.setFillColor(color(c.0, c.1, c.2)); ctx.fillPath()
            }
            text("Pipeline", 20, 165, size: 16, bold: true)
            panel(192, 165)
            for (k, label) in ["Image type", "Exact pixels", "Tracing"].enumerated() {
                let top = 205 + Double(k) * 55
                text(label, 25, top + 4)
                text("Auto", 300, top + 4)
                ctx.setFillColor(color(0.24, 0.24, 0.25)); ctx.fillEllipse(in: CGRect(x: 350, y: y(top + 26), width: 24, height: 24))
                if k < 2 { ctx.setFillColor(color(0.22, 0.22, 0.23)); ctx.fill(CGRect(x: 25, y: y(top + 45), width: 355, height: 1)) }
            }
            text("Shape", 20, 380, size: 16, bold: true)
            panel(405, 140)
            for (k, label) in ["Colors", "Detail"].enumerated() {
                let top = 418 + Double(k) * 62
                text(label, 25, top)
                ctx.setFillColor(color(0.26, 0.26, 0.27)); ctx.fill(CGRect(x: 160, y: y(top + 32), width: 220, height: 5))
                ctx.setFillColor(color(0.25, 0.45, 0.85)); ctx.fill(CGRect(x: 160, y: y(top + 32), width: 70, height: 5))
                ctx.setFillColor(color(0.75, 0.75, 0.76)); ctx.fillEllipse(in: CGRect(x: 220, y: y(top + 42), width: 24, height: 24))
            }
        }
    }

    /// A smooth "photo": a gently shaded wall, a softly lit face-like ellipse, textured hair, a
    /// garment with fabric grain, and faint sensor noise — large smooth areas (low shading score)
    /// but nowhere near a few flat colors.
    static func smoothPhoto() -> Bitmap {
        var rng = SplitMix64(seed: 11)
        func noise(_ a: Double) -> Double { Double(rng.next() % 1000) / 1000 * 2 * a - a }
        let w = 300, h = 400
        return Bitmap(width: w, height: h) { x, y in
            let fx = Double(x), fy = Double(y)
            // Wall: very gentle diagonal light falloff.
            var c = SIMD3(245 - fx * 0.3 - fy * 0.15, 230 - fx * 0.25 - fy * 0.2, 205 - fx * 0.35 - fy * 0.15)
            let face = pow((fx - 150) / 70, 2) + pow((fy - 190) / 95, 2)
            let hair = pow((fx - 150) / 82, 2) + pow((fy - 120) / 70, 2)
            if fy > 300 {   // garment with grain
                c = SIMD3(40 + noise(3) + fx * 0.12, 55 + noise(3) + fx * 0.1, 110 + noise(4) + fx * 0.15) * (1 - (fy - 300) / 400)
            } else if face < 1 {   // skin, lit from the upper left
                let light = 1 - 0.35 * face - 0.0015 * (fx - 110) - 0.001 * (fy - 150)
                c = SIMD3(222, 170, 140) * light
            } else if hair < 1 && fy < 160 {   // hair texture
                c = SIMD3(95 + fx * 0.2, 85 + fx * 0.15, 75) + SIMD3(repeating: noise(6))
            }
            // Slow, independent color drift in each channel (lighting, reflections, skin tone),
            // too gradual to read as shading but far from a handful of flat colors.
            c += SIMD3(30 * sin(fx / 170 + fy / 210), 30 * sin(fx / 180 - fy / 145 + 1), 32 * sin(-fx / 175 + fy / 130 + 2))
            c += SIMD3(noise(1.5), noise(1.5), noise(1.5))
            let v = c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 255))
            return RGBA(UInt8(v.x), UInt8(v.y), UInt8(v.z))
        }
    }
}
