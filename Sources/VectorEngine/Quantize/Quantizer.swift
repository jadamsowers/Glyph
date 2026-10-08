import simd
public struct QuantizeParams: Sendable, Equatable {
    public var kind: ImageKind
    public var colorCount: Int
    public var alphaThreshold: UInt8 = 128
    public var mergeDistance: Double = 10
    public var minColorShare: Double = 0.001
    public var blendSlack: Double = 0.15
    public var blendKeepShare: Double = 0.03
    public var kmeansIterations: Int = 12
    public var kmeansSampleSize: Int = 20_000
    /// Black-and-white mode (overrides `kind`).
    public var monochrome: Monochrome? = nil

    public init(kind: ImageKind, colorCount: Int) {
        self.kind = kind
        self.colorCount = colorCount
    }
}

/// Every pixel mapped to a palette entry; -1 marks transparent pixels.
public struct QuantizedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let palette: [RGBA]
    public let indices: [Int32]

    public func makeBitmap() -> Bitmap {
        Bitmap(width: width, height: height, pixels: indices.map { $0 < 0 ? .clear : palette[Int($0)] })
    }
}

enum Quantizer {
    /// Logo palette: dominant flat colors, ignoring anti-aliasing blends.
    static func logo(_ bitmap: Bitmap, params p: QuantizeParams) -> QuantizedImage {
        let (clusters, total) = PaletteBuilder.clusters(of: bitmap, alphaThreshold: p.alphaThreshold, mergeDistance: p.mergeDistance)
        let chosen = PaletteBuilder.palette(
            from: clusters, total: total, maxColors: p.colorCount, minShare: p.minColorShare,
            blendSlack: p.blendSlack, blendKeepShare: p.blendKeepShare)
        return refineBlends(assign(bitmap, palette: chosen.map(\.color), alphaThreshold: p.alphaThreshold), bitmap)
    }

    /// Second pass for anti-aliased edges: a pixel whose raw color is a mix (see
    /// `PaletteBuilder.isBlend`) of two *other* palette colors present in its 3×3 neighbourhood
    /// joins the nearer of those two — not some third color that is merely numerically nearest,
    /// which would leave a thin band of the wrong region along the edge. Pixels that match their
    /// palette color closely (≤ 4 per channel) are never changed. Repeats until stable (at most
    /// `maxPasses`), peeling bands wider than a pixel — e.g. anti-aliasing ramps after upscaling —
    /// from both sides toward the true edge.
    static func refineBlends(_ q: QuantizedImage, _ bitmap: Bitmap, slack: Double = 0.15, maxPasses: Int = 12) -> QuantizedImage {
        var current = q
        for _ in 0..<maxPasses {
            let next = refineBlendsOnce(current, bitmap, slack: slack)
            if next.indices == current.indices { break }
            current = next
        }
        return current
    }

    static func refineBlendsOnce(_ q: QuantizedImage, _ bitmap: Bitmap, slack: Double) -> QuantizedImage {
        let w = q.width, h = q.height
        guard q.palette.count >= 3 else { return q }
        let labs = q.palette.map { Lab($0) }
        func rgb(_ c: RGBA) -> SIMD3<Double> { SIMD3(Double(c.r), Double(c.g), Double(c.b)) }
        let pal = q.palette.map(rgb)
        var out = q.indices
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, own = Int(q.indices[i])
                guard own >= 0 else { continue }
                let c = bitmap.pixels[i]
                let pc = q.palette[own]
                if max(abs(Int(c.r) - Int(pc.r)), abs(Int(c.g) - Int(pc.g)), abs(Int(c.b) - Int(pc.b))) <= 4 { continue }
                var around = Set<Int>()
                for dy in -1...1 {
                    for dx in -1...1 where (dx, dy) != (0, 0) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let k = Int(q.indices[ny * w + nx])
                        if k >= 0 && k != own { around.insert(k) }
                    }
                }
                guard around.count >= 2 else { continue }
                let v = rgb(c)
                var best: (Int, Double)?
                let candidates = Array(around)
                for a in candidates.indices {
                    for b in candidates.indices where b > a {
                        let pa = pal[candidates[a]], pb = pal[candidates[b]]
                        let direct = simd_distance(pa, pb)
                        guard direct > 0, simd_distance(pa, v) + simd_distance(v, pb) <= direct * (1 + slack) else { continue }
                        let lab = Lab(c)
                        for k in [candidates[a], candidates[b]] {
                            let d = labs[k].distance(to: lab)
                            if best == nil || d < best!.1 { best = (k, d) }
                        }
                    }
                }
                if let (k, _) = best { out[i] = Int32(k) }
            }
        }
        return QuantizedImage(width: w, height: h, palette: q.palette, indices: out)
    }

    /// Maps each opaque pixel to the perceptually nearest palette color.
    static func assign(_ bitmap: Bitmap, palette: [RGBA], alphaThreshold: UInt8) -> QuantizedImage {
        let labs = palette.map { Lab($0) }
        var cache: [UInt32: Int32] = [:]
        var indices = [Int32](repeating: -1, count: bitmap.pixels.count)
        if !palette.isEmpty {
            for (i, p) in bitmap.pixels.enumerated() where p.a >= alphaThreshold {
                if let hit = cache[p.rgbKey] { indices[i] = hit; continue }
                let lab = Lab(p)
                var best = 0, bestD = Double.infinity
                for (j, q) in labs.enumerated() {
                    let d = q.distance(to: lab)
                    if d < bestD { bestD = d; best = j }
                }
                cache[p.rgbKey] = Int32(best)
                indices[i] = Int32(best)
            }
        }
        return QuantizedImage(width: bitmap.width, height: bitmap.height, palette: palette, indices: indices)
    }
}
