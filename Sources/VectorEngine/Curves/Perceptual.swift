import Foundation

/// Perceptual weighting: spend geometric precision where the eye can see it.
enum Perceptual {
    /// How much looser a boundary between two colors may be traced: `reference / ΔE`, clamped to
    /// 1…`cap`. High-contrast edges (ΔE ≥ reference) keep the base tolerance; edges against
    /// transparency (nil) always do.
    static func toleranceMultiplier(_ a: RGBA?, _ b: RGBA?, reference: Double, cap: Double = 4) -> Double {
        guard let a, let b else { return 1 }
        return min(cap, max(1, reference / max(Lab(a).distance(to: Lab(b)), 1e-6)))
    }

    /// Visibility weight of a boundary for simplification costs: ΔE / reference, within 0.6…1.
    /// The floor keeps faint edges from bowing visibly: shape distortion shows even at low contrast.
    static func visibility(_ a: RGBA?, _ b: RGBA?, reference: Double) -> Double {
        guard let a, let b else { return 1 }
        return max(0.6, min(1, Lab(a).distance(to: Lab(b)) / reference))
    }

    /// The two colors each chain separates (nil = transparency / outside).
    static func chainColors(_ t: Topology, _ regions: [Region]) -> [(RGBA?, RGBA?)] {
        t.chains.map { c in
            (c.left >= 0 ? regions[Int(c.left)].color : nil, c.right >= 0 ? regions[Int(c.right)].color : nil)
        }
    }

    /// Fraction of pixels whose rendered color differs visibly (ΔE > 10, or opaque vs transparent)
    /// from `reference`, compared with the long side at `compareSize` (at most 512 px) — the
    /// display size when one is set, since that's where the difference would be seen.
    static func visibleDifference(_ shapes: [VectorShape], outputWidth: Int, outputHeight: Int, reference: Bitmap,
                                  compareSize: Int = 512) -> Double {
        let s = min(1, Double(min(512, max(8, compareSize))) / Double(max(reference.width, reference.height)))
        let w = max(1, Int((Double(reference.width) * s).rounded())), h = max(1, Int((Double(reference.height) * s).rounded()))
        // What a display shows at that size: a smooth (area-averaging) downscale of the source.
        let shown = w == reference.width && h == reference.height ? reference : Bitmap(cgImage: reference.makeCGImage(), width: w, height: h)
        let rendered = Bitmap.render(width: w, height: h) { ctx in
            ctx.scaleBy(x: Double(w) / Double(outputWidth), y: Double(h) / Double(outputHeight))
            ShapeRenderer.fill(shapes, in: ctx)
        }
        var labs: [UInt32: Lab] = [:]
        func lab(_ c: RGBA) -> Lab {
            if let l = labs[c.rgbKey] { return l }
            let l = Lab(c); labs[c.rgbKey] = l; return l
        }
        var differing = 0
        for y in 0..<h {
            for x in 0..<w {
                let a = rendered[x, y], b = shown[x, y]
                let aOpaque = a.a >= 128, bOpaque = b.a >= 128
                if aOpaque != bOpaque || (aOpaque && lab(a).distance(to: lab(b)) > 10) { differing += 1 }
            }
        }
        return Double(differing) / Double(w * h)
    }
}
