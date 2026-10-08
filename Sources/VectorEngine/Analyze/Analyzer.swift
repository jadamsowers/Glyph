import simd
public struct Analysis: Sendable, Equatable {
    public var kind: ImageKind
    /// Distinct colors after merging near-duplicates and ignoring anti-aliasing blends.
    public var significantColors: Int
    /// Share of pixels showing soft, gradual change (shading, texture).
    public var gradientFraction: Double
    /// The significant colors, most common first, and their share of opaque pixels.
    public var palette: [RGBA]
    public var shares: [Double]
    /// Share of pixels at hard edges (box-averaged change above 40): logos have few; noise is all edge.
    public var edgeFraction: Double = 0
    /// Hard-edged, unblended pixels (pixel art, or shapes drawn without anti-aliasing): every
    /// staircase step is real, so the image is traced exactly along pixel edges.
    public var isPixelArt: Bool = false
}

public struct ClassifierParams: Sendable, Equatable {
    public var alphaThreshold: UInt8 = 128
    public var mergeDistance: Double = 10
    public var minColorShare: Double = 0.001
    public var blendSlack: Double = 0.15
    public var blendKeepShare: Double = 0.03
    public var logoMaxColors = 32
    public var logoMaxGradientFraction = 0.35
    public var logoMaxEdgeFraction = 0.35
    public var sampleDimension = 256

    public init() {}
}

enum Analyzer {
    static func analyze(_ bitmap: Bitmap, params p: ClassifierParams) -> Analysis {
        let sample = downsample(bitmap, to: p.sampleDimension)
        let (clusters, total) = PaletteBuilder.clusters(of: sample, alphaThreshold: p.alphaThreshold, mergeDistance: p.mergeDistance)
        let palette = PaletteBuilder.palette(
            from: clusters, total: total, maxColors: p.logoMaxColors + 1, minShare: p.minColorShare,
            blendSlack: p.blendSlack, blendKeepShare: p.blendKeepShare)
        let (gradient, edges) = changeFractions(sample, alphaThreshold: p.alphaThreshold)
        let pixelArt = looksLikePixelArt(bitmap, alphaThreshold: p.alphaThreshold)
        // Pixel art is flat by construction, however dense its edges.
        let isLogo = pixelArt || (palette.count <= p.logoMaxColors && gradient < p.logoMaxGradientFraction && edges < p.logoMaxEdgeFraction)
        return Analysis(
            kind: isLogo ? .logo : .photo, significantColors: palette.count, gradientFraction: gradient,
            palette: palette.map(\.color), shares: palette.map { total > 0 ? Double($0.count) / Double(total) : 0 },
            edgeFraction: edges, isPixelArt: pixelArt)
    }

    /// Whether the image's edges are hard and unblended. Judged only at "stair" pixels — edge
    /// pixels that differ from both a horizontal and a vertical neighbour — because axis-aligned
    /// edges look the same with or without anti-aliasing; diagonals and curves are where blending
    /// shows. Anti-aliasing leaves one-off blend shades there; pixel art only uses colors that also
    /// appear in flat runs (a pixel equal to both its horizontal or both its vertical neighbours).
    /// True if at least 95% of stair pixels have such a "run" color (and there are enough to judge).
    public static func looksLikePixelArt(_ bitmap: Bitmap, alphaThreshold: UInt8 = 128) -> Bool {
        let b = downsample(bitmap, to: 512)
        let w = b.width, h = b.height
        func key(_ p: RGBA) -> UInt32 { p.a < alphaThreshold ? .max : p.rgbKey }
        func differs(_ p: RGBA, _ q: RGBA) -> Bool {
            if (p.a < alphaThreshold) != (q.a < alphaThreshold) { return true }
            if p.a < alphaThreshold { return false }
            return max(abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b))) >= 16
        }
        var runColors = Set<UInt32>()
        for y in 0..<h {
            for x in 0..<w {
                let k = key(b[x, y])
                if (x > 0 && x < w - 1 && key(b[x - 1, y]) == k && key(b[x + 1, y]) == k)
                    || (y > 0 && y < h - 1 && key(b[x, y - 1]) == k && key(b[x, y + 1]) == k) { runColors.insert(k) }
            }
        }
        var edges = 0, hard = 0
        for y in 0..<h {
            for x in 0..<w {
                let p = b[x, y]
                let horizontal = (x > 0 && differs(p, b[x - 1, y])) || (x < w - 1 && differs(p, b[x + 1, y]))
                let vertical = (y > 0 && differs(p, b[x, y - 1])) || (y < h - 1 && differs(p, b[x, y + 1]))
                guard horizontal && vertical else { continue }
                edges += 1
                if runColors.contains(key(p)) { hard += 1 }
            }
        }
        return edges >= 8 && Double(hard) >= 0.95 * Double(edges)
    }

    /// Nearest-neighbor downsample so the long side is at most `maxSide`.
    static func downsample(_ b: Bitmap, to maxSide: Int) -> Bitmap {
        let longSide = max(b.width, b.height)
        guard longSide > maxSide else { return b }
        let w = max(1, b.width * maxSide / longSide), h = max(1, b.height * maxSide / longSide)
        return Bitmap(width: w, height: h) { x, y in b[x * b.width / w, y * b.height / h] }
    }

    /// Share of opaque pixels showing shading or texture rather than flat color: shading is a
    /// 3×3 box-averaged change of 2.5…40 over 3 px that is spread out (the pixel's own 3×3 range
    /// is below that change), texture a moderate raw range (16…64) without hard edges. Flat logos,
    /// text and UI score low; photos and gradients high.
    static func gradientFraction(_ b: Bitmap, alphaThreshold: UInt8) -> Double {
        changeFractions(b, alphaThreshold: alphaThreshold).gradient
    }

    /// (soft-change share, hard-edge share) — see `gradientFraction`; hard edges are changes above 40.
    static func changeFractions(_ b: Bitmap, alphaThreshold: UInt8) -> (gradient: Double, edges: Double) {
        let w = b.width, h = b.height, d = 3
        guard w > 2 + d, h > 2 + d else { return (0, 0) }
        var avg = [SIMD3<Int32>](repeating: .zero, count: w * h)
        var solid = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s = SIMD3<Int32>.zero, ok = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        let p = b[x + dx, y + dy]
                        if p.a < alphaThreshold { ok = false }
                        s &+= SIMD3(Int32(p.r), Int32(p.g), Int32(p.b))
                    }
                }
                avg[y * w + x] = s
                solid[y * w + x] = ok
            }
        }
        // Raw contrast within each pixel's 3×3 neighbourhood. Shading spreads its change over
        // several pixels, so the immediate range is smaller than the change over 3 px; a low-
        // contrast step edge (UI panels) or a text halo concentrates it in one step. Texture
        // (grain, foliage) is moderate raw range without hard edges.
        var localRange = [Int](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var lo = SIMD3<Int32>(repeating: 255), hi = SIMD3<Int32>(repeating: 0)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let p = b[x + dx, y + dy]
                        let v = SIMD3(Int32(p.r), Int32(p.g), Int32(p.b))
                        lo = simd_min(lo, v); hi = simd_max(hi, v)
                    }
                }
                let r = hi &- lo
                localRange[y * w + x] = Int(max(r.x, r.y, r.z))
            }
        }
        var soft = 0, hard = 0, counted = 0
        for y in 1..<(h - 1 - d) {
            for x in 1..<(w - 1 - d) {
                let i = y * w + x
                guard solid[i], solid[i + d], solid[i + d * w] else { continue }
                counted += 1
                func diff(_ j: Int) -> Double {
                    let v = avg[i] &- avg[j]
                    return Double(max(abs(v.x), abs(v.y), abs(v.z))) / 9
                }
                let m = max(diff(i + d), diff(i + d * w))
                let range = Double(localRange[i])
                let shading = m >= 2.5 && m <= 40 && range <= 0.85 * m + 3
                let texture = m <= 40 && range > 16 && range <= 64
                if shading || texture { soft += 1 } else if m > 40 { hard += 1 }
            }
        }
        return counted == 0 ? (0, 0) : (Double(soft) / Double(counted), Double(hard) / Double(counted))
    }
}
