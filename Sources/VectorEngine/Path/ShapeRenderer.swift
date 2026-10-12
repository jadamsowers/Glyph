import CoreGraphics

public enum ShapeRenderer {
    public static func path(for shape: VectorShape) -> CGPath {
        let p = CGMutablePath()
        for sp in shape.subpaths {
            p.move(to: cg(sp.start))
            for seg in sp.segments {
                switch seg {
                case .line(let to): p.addLine(to: cg(to))
                case .cubic(let c1, let c2, let to): p.addCurve(to: cg(to), control1: cg(c1), control2: cg(c2))
                }
            }
            if sp.isClosed { p.closeSubpath() }
        }
        return p
    }

    /// Fills shapes in order with the even-odd rule. `ctx` must use y-down coordinates. A positive
    /// `seamStroke` first strokes every outline in its own color beneath all fills, so anti-aliased
    /// edges between neighbors show shape colors instead of the background.
    public static func fill(_ shapes: [VectorShape], seamStroke: Double = 0, in ctx: CGContext) {
        if seamStroke > 0 {
            ctx.setLineWidth(seamStroke)
            ctx.setLineJoin(.round)
            for s in shapes {
                ctx.addPath(path(for: s))
                ctx.setStrokeColor(cgColor(s.color))
                ctx.strokePath()
            }
        }
        for s in shapes {
            ctx.addPath(path(for: s))
            if let width = s.stroke {
                ctx.setStrokeColor(cgColor(s.color))
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            } else {
                ctx.setFillColor(cgColor(s.color))
                ctx.fillPath(using: .evenOdd)
            }
        }
    }

    public static func rasterize(_ shapes: [VectorShape], width: Int, height: Int, antialias: Bool = true,
                                 background: RGBA = .clear, seamStroke: Double = 0) -> Bitmap {
        Bitmap.render(width: width, height: height) { ctx in
            if background.a > 0 {
                ctx.setFillColor(cgColor(background))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            ctx.setShouldAntialias(antialias)
            fill(shapes, seamStroke: seamStroke, in: ctx)
        }
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    static func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
}
