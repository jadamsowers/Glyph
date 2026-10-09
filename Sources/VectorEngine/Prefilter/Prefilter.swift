import Foundation

public struct PrefilterParams: Sendable, Equatable {
    public var enabled: Bool
    public var radius: Int = 2
    public var sigmaColor: Double = 24
    public var alphaThreshold: UInt8 = 128
    /// Transparent margin added on every side (processing px).
    public var border = 0
    public var adjust = Adjustments()
    /// Median denoise radius (processing px); 0 = off.
    public var medianRadius = 0

    public init(enabled: Bool) { self.enabled = enabled }
}

enum Prefilter {
    static func apply(_ b: Bitmap, params p: PrefilterParams) -> Bitmap {
        var img = adjust(b, p.adjust)
        img = median(img, radius: p.medianRadius, alphaThreshold: p.alphaThreshold)
        if p.enabled && p.radius > 0 { img = bilateral(img, radius: p.radius, sigmaColor: p.sigmaColor, alphaThreshold: p.alphaThreshold) }
        return img.padded(by: p.border)
    }

    /// Edge-preserving blur: each neighbor is weighted by spatial distance and color similarity.
    static func bilateral(_ src: Bitmap, radius: Int, sigmaColor: Double, alphaThreshold: UInt8) -> Bitmap {
        let sigmaSpace = Double(radius) / 2 + 0.5
        var spatial: [Double] = []
        for dy in -radius...radius {
            for dx in -radius...radius { spatial.append(exp(-Double(dx * dx + dy * dy) / (2 * sigmaSpace * sigmaSpace))) }
        }
        // Color weight table indexed by squared RGB distance / 16.
        let denominator = 2 * sigmaColor * sigmaColor
        let colorWeight = (0...(3 * 255 * 255 / 16 + 1)).map { (key: Int) -> Double in exp(-Double(key * 16) / denominator) }
        let w = src.width, h = src.height
        var out = src
        for y in 0..<h {
            for x in 0..<w {
                let c = src[x, y]
                guard c.a >= alphaThreshold else { continue }
                var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0, k = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        defer { k += 1 }
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let n = src[nx, ny]
                        guard n.a >= alphaThreshold else { continue }
                        let dr = Int(n.r) - Int(c.r), dg = Int(n.g) - Int(c.g), db = Int(n.b) - Int(c.b)
                        let wgt = spatial[k] * colorWeight[(dr * dr + dg * dg + db * db) / 16]
                        sr += wgt * Double(n.r); sg += wgt * Double(n.g); sb += wgt * Double(n.b); sw += wgt
                    }
                }
                out[x, y] = RGBA(UInt8((sr / sw).rounded()), UInt8((sg / sw).rounded()), UInt8((sb / sw).rounded()), c.a)
            }
        }
        return out
    }
}
