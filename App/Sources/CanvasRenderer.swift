import CoreGraphics
import VectorEngine

/// Draws the canvas — checkerboard, the vector, the wipe against the original, and the curve-edit
/// overlay — into a y-down context. Shared by the Mac (`CanvasNSView`) and iOS (`CanvasUIView`)
/// hosts, which own input handling.
struct CanvasRenderer {
    var bounds: CGRect
    var vector: ShapeRenderer.Prepared?
    var original: CGImage?
    var outputSize = CGSize(width: 1, height: 1)
    var zoom: Double?
    var pan = CGSize.zero
    var split = 0.5
    var dark = false
    var accent: CGColor
    /// Set while editing curves.
    var editor: CurveEditor?
    var selectedChain: Int?
    var hoveredChain: Int?
    /// Curve coordinates → output units.
    var curveTransform = CGAffineTransform.identity

    var editing: Bool { editor != nil }

    // MARK: Geometry

    var fitScale: Double {
        max(0.0001, min((bounds.width - 40) / outputSize.width, (bounds.height - 40) / outputSize.height))
    }
    var scale: Double { zoom ?? fitScale }
    /// Top-left of the image in view coordinates.
    var origin: CGPoint {
        CGPoint(x: (bounds.width - outputSize.width * scale) / 2 + pan.width,
                y: (bounds.height - outputSize.height * scale) / 2 + pan.height)
    }
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Curve coordinates → view.
    var viewTransform: CGAffineTransform {
        let o = origin, s = scale
        return curveTransform.concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: o.x, y: o.y))
    }

    // MARK: Drawing

    func draw(in ctx: CGContext) {
        drawCheckerboard(ctx)
        guard let vector else { return }
        let o = origin, s = scale
        let divider = bounds.width * split
        let compare = original != nil && !editing

        ctx.saveGState()
        if compare { ctx.clip(to: CGRect(x: 0, y: 0, width: divider, height: bounds.height)) }
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: s, y: s)
        vector.draw(in: ctx)
        ctx.restoreGState()

        if let original, compare {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: divider, y: 0, width: bounds.width - divider, height: bounds.height))
            ctx.translateBy(x: o.x, y: o.y + outputSize.height * s)
            ctx.scaleBy(x: s, y: -s)
            // Zoomed in, show the actual pixels rather than a blur of them.
            ctx.interpolationQuality = s > 2 ? .none : .high
            ctx.draw(original, in: CGRect(origin: .zero, size: outputSize))
            ctx.restoreGState()
            drawDivider(ctx, at: divider)
        }
        if editing { drawEditOverlay(ctx) }
    }

    private func drawEditOverlay(_ ctx: CGContext) {
        guard let editor else { return }
        let t = viewTransform
        func path(_ chain: Int) -> CGPath {
            let c = editor.curves[chain]
            return ShapeRenderer.path(for: VectorShape(color: .clear, subpaths: [Subpath(start: c.start, segments: c.segments, isClosed: false)]))
        }
        ctx.saveGState()
        ctx.setLineJoin(.round)
        if let h = hoveredChain, h != selectedChain, h < editor.curves.count {
            ctx.addPath(path(h).copy(using: [t]) ?? path(h))
            ctx.setStrokeColor(accent.copy(alpha: 0.6) ?? accent)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        if let c = selectedChain, c < editor.curves.count {
            // A white casing keeps the outline visible on any fill.
            let p = path(c).copy(using: [t]) ?? path(c)
            for (color, width) in [(CGColor.white, 3.5), (accent, 1.5)] {
                ctx.addPath(p)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }
            let handles = editor.handles(of: c).map { (anchor: $0.anchor.cg.applying(t), handle: $0.handle.cg.applying(t)) }
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1)
            for h in handles {
                ctx.move(to: h.anchor)
                ctx.addLine(to: h.handle)
            }
            ctx.strokePath()
            for h in handles {
                let r = CGRect(x: h.handle.x - 3.5, y: h.handle.y - 3.5, width: 7, height: 7)
                ctx.setFillColor(.white)
                ctx.fillEllipse(in: r)
                ctx.setStrokeColor(accent)
                ctx.strokeEllipse(in: r)
            }
            for a in editor.anchors(of: c) {
                let p = a.cg.applying(t)
                let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.setFillColor(accent)
                ctx.fill(r)
                ctx.setStrokeColor(.white)
                ctx.stroke(r)
            }
        }
        ctx.restoreGState()
    }

    private func drawCheckerboard(_ ctx: CGContext) {
        let base = dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.98, alpha: 1)
        let alt = dark ? CGColor(gray: 0.19, alpha: 1) : CGColor(gray: 0.88, alpha: 1)
        ctx.setFillColor(base)
        ctx.fill(bounds)
        ctx.setFillColor(alt)
        let cell: CGFloat = 10
        for y in stride(from: 0, to: bounds.height, by: cell) {
            for x in stride(from: 0, to: bounds.width, by: cell) where (Int(x / cell) + Int(y / cell)).isMultiple(of: 2) {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
    }

    private func drawDivider(_ ctx: CGContext, at x: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: x - 1, y: 0, width: 2, height: bounds.height))
        let knob = CGRect(x: x - 14, y: bounds.midY - 14, width: 28, height: 28)
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: knob)
        ctx.restoreGState()
        // ← → arrows
        ctx.setFillColor(.white)
        for dir: CGFloat in [-1, 1] {
            let tip = CGPoint(x: x + dir * 9, y: bounds.midY)
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: x + dir * 3, y: bounds.midY - 5))
            ctx.addLine(to: CGPoint(x: x + dir * 3, y: bounds.midY + 5))
            ctx.closePath()
        }
        ctx.fillPath()
    }
}

private extension Vec2 {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}
