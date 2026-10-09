import CoreGraphics
import Foundation

/// Draws a picture of each pipeline stage, for the app's stage timeline and `vectorize --stages`.
public enum StageRenderer {
    static let ink = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.12, alpha: 1)
    static let cornerColor = CGColor(srgbRed: 0.93, green: 0.30, blue: 0.15, alpha: 1)
    static let smoothColor = CGColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1)
    static let handleColor = CGColor(srgbRed: 0.45, green: 0.45, blue: 0.50, alpha: 0.8)

    /// A picture of `stage` at processing resolution × `scale`, or nil if the stage hasn't run.
    public static func image(for stage: Stage, in s: PipelineState, scale: Double = 1) -> CGImage? {
        let w = max(1, Int((Double(s.input.bitmap.width) * scale).rounded()))
        let h = max(1, Int((Double(s.input.bitmap.height) * scale).rounded()))
        switch stage {
        case .analyze:
            guard let a = s.analysis else { return nil }
            return draw(w, h) { ctx in
                drawUpright(s.input.bitmap.makeCGImage(), in: ctx, width: w, height: h)
                // Palette strip along the bottom; each swatch is as wide as its share.
                let stripH = max(4, Double(h) * 0.12)
                let total = max(a.shares.reduce(0, +), 1e-9)
                var x = 0.0
                for (c, share) in zip(a.palette, a.shares) {
                    let sw = Double(w) * share / total
                    ctx.setFillColor(ShapeRenderer.cgColor(c))
                    ctx.fill(CGRect(x: x, y: Double(h) - stripH, width: sw, height: stripH))
                    x += sw
                }
            }
        case .prefilter:
            return s.prefiltered.map { pixels($0, w, h) }
        case .quantize:
            return s.quantized.map { pixels($0.makeBitmap(), w, h) }
        case .segment:
            return s.segmentation.map { pixels(falseColor($0), w, h) }
        case .contours:
            guard let q = s.quantized, let t = s.topology else { return nil }
            return overlay(q, w, h, scale) { ctx, px in
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(px)
                for c in t.chains { addPolyline(ctx, c.points.map(\.vec)) }
                ctx.strokePath()
            }
        case .polygon:
            guard let q = s.quantized, let polys = s.polygons else { return nil }
            return overlay(q, w, h, scale) { ctx, px in
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(px)
                for p in polys { addPolyline(ctx, p.isClosed ? p.polygon + [p.polygon[0]] : p.polygon) }
                ctx.strokePath()
                for p in polys {
                    for (v, corner) in zip(p.polygon, p.corners) { dot(ctx, v, radius: 1.6 * px, color: corner ? cornerColor : smoothColor) }
                }
            }
        case .curves:
            guard let q = s.quantized, let curves = s.curves else { return nil }
            return overlay(q, w, h, scale) { ctx, px in
                ctx.setStrokeColor(handleColor)
                ctx.setLineWidth(px * 0.6)
                for c in curves {
                    var cur = c.start
                    for seg in c.segments {
                        if case .cubic(let c1, let c2, let to) = seg {
                            ctx.move(to: cg(cur)); ctx.addLine(to: cg(c1))
                            ctx.move(to: cg(to)); ctx.addLine(to: cg(c2))
                        }
                        cur = seg.end
                    }
                }
                ctx.strokePath()
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(px)
                for c in curves { ctx.addPath(path(c)) }
                ctx.strokePath()
                for c in curves { for seg in c.segments { dot(ctx, seg.end, radius: 1.3 * px, color: ink) } }
            }
        case .svg:
            guard let r = s.result else { return nil }
            // The result may be rotated or bordered: size the picture from its own dimensions.
            let k = scale * Double(s.input.bitmap.width) / Double(s.input.originalWidth)
            let w = max(1, Int((Double(r.width) * k).rounded())), h = max(1, Int((Double(r.height) * k).rounded()))
            return draw(w, h) { ctx in
                ctx.scaleBy(x: Double(w) / Double(r.width), y: Double(h) / Double(r.height))
                ShapeRenderer.fill(r.shapes, seamStroke: r.seamStroke, in: ctx)
            }
        }
    }

    /// Each region in a distinct hue (golden-ratio steps), transparency kept.
    static func falseColor(_ seg: Segmentation) -> Bitmap {
        let palette = (0..<seg.regions.count).map { i -> RGBA in
            let hue = (Double(i) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            return hsv(hue, 0.55, 0.95)
        }
        return Bitmap(width: seg.width, height: seg.height, pixels: seg.labels.map { $0 < 0 ? .clear : palette[Int($0)] })
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGBA {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return RGBA(UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    // MARK: Drawing helpers (all contexts are y-down)

    static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Bitmap.colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()!
    }

    /// Draws an image the right way up inside a y-down context.
    static func drawUpright(_ image: CGImage, in ctx: CGContext, width: Int, height: Int) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    static func pixels(_ b: Bitmap, _ w: Int, _ h: Int) -> CGImage {
        draw(w, h) { drawUpright(b.makeCGImage(), in: $0, width: w, height: h) }
    }

    /// The quantized image, faded, with `body` drawn on top in lattice coordinates.
    /// `body` receives the size of one output pixel in lattice units.
    static func overlay(_ q: QuantizedImage, _ w: Int, _ h: Int, _ scale: Double, _ body: (CGContext, Double) -> Void) -> CGImage {
        draw(w, h) { ctx in
            drawUpright(q.makeBitmap().makeCGImage(), in: ctx, width: w, height: h)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: Double(w) / Double(q.width), y: Double(h) / Double(q.height))
            ctx.setLineJoin(.round)
            body(ctx, Double(q.width) / Double(w))
        }
    }

    static func addPolyline(_ ctx: CGContext, _ pts: [Vec2]) {
        guard let first = pts.first else { return }
        ctx.move(to: cg(first))
        for p in pts.dropFirst() { ctx.addLine(to: cg(p)) }
    }

    static func path(_ c: Curve) -> CGPath {
        let p = CGMutablePath()
        p.move(to: cg(c.start))
        for seg in c.segments {
            switch seg {
            case .line(let to): p.addLine(to: cg(to))
            case .cubic(let c1, let c2, let to): p.addCurve(to: cg(to), control1: cg(c1), control2: cg(c2))
            }
        }
        return p
    }

    static func dot(_ ctx: CGContext, _ v: Vec2, radius: Double, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: v.x - radius, y: v.y - radius, width: radius * 2, height: radius * 2))
    }

    static func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
}
