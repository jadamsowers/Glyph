import Foundation
import simd

extension Bitmap {
    /// Smooth Catmull-Rom (bicubic) upscale by an integer factor, in premultiplied space so
    /// transparent pixels don't bleed their (meaningless) color. Anti-aliased edges become smooth
    /// ramps, so a later threshold recovers their sub-pixel position.
    public func upscaled(by factor: Int) -> Bitmap {
        guard factor > 1 else { return self }
        let w = width, h = height, W = w * factor, H = h * factor
        // Premultiplied channels as Doubles.
        var pre = [SIMD4<Double>](repeating: .zero, count: w * h)
        for (i, p) in pixels.enumerated() {
            let a = Double(p.a) / 255
            pre[i] = SIMD4(Double(p.r) * a, Double(p.g) * a, Double(p.b) * a, Double(p.a))
        }
        func weights(_ t: Double) -> SIMD4<Double> {
            let t2 = t * t, t3 = t2 * t
            return SIMD4(-0.5 * t3 + t2 - 0.5 * t,
                         1.5 * t3 - 2.5 * t2 + 1,
                         -1.5 * t3 + 2 * t2 + 0.5 * t,
                         0.5 * t3 - 0.5 * t2)
        }
        var out = [RGBA](repeating: .clear, count: W * H)
        for Y in 0..<H {
            let sy = (Double(Y) + 0.5) / Double(factor) - 0.5
            let y0 = Int(sy.rounded(.down)), wy = weights(sy - Double(y0))
            for X in 0..<W {
                let sx = (Double(X) + 0.5) / Double(factor) - 0.5
                let x0 = Int(sx.rounded(.down)), wx = weights(sx - Double(x0))
                var acc = SIMD4<Double>.zero
                for j in 0..<4 {
                    let yy = min(h - 1, max(0, y0 - 1 + j))
                    var row = SIMD4<Double>.zero
                    for i in 0..<4 {
                        let xx = min(w - 1, max(0, x0 - 1 + i))
                        row += pre[yy * w + xx] * wx[i]
                    }
                    acc += row * wy[j]
                }
                // Clamp to the 2×2 nearest source pixels: Catmull-Rom overshoots beside hard
                // edges, and those ripples would be traced as detail.
                let xa = min(w - 1, max(0, x0)), xb = min(w - 1, x0 + 1), ya = min(h - 1, max(0, y0)), yb = min(h - 1, y0 + 1)
                let n = [pre[ya * w + xa], pre[ya * w + xb], pre[yb * w + xa], pre[yb * w + xb]]
                acc = simd_clamp(acc, n.dropFirst().reduce(n[0]) { simd_min($0, $1) }, n.dropFirst().reduce(n[0]) { simd_max($0, $1) })
                let a = min(255, max(0, acc.w))
                guard a >= 0.5 else { continue }
                let k = 255 / a
                out[Y * W + X] = RGBA(UInt8(min(255, max(0, acc.x * k)).rounded()), UInt8(min(255, max(0, acc.y * k)).rounded()),
                                      UInt8(min(255, max(0, acc.z * k)).rounded()), UInt8(a.rounded()))
            }
        }
        return Bitmap(width: W, height: H, pixels: out)
    }
}
