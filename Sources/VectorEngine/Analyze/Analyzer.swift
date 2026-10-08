public struct Analysis: Sendable, Equatable {
    public var kind: ImageKind
    /// Distinct colors after merging near-duplicates and ignoring anti-aliasing blends.
    public var significantColors: Int
    /// Share of pixels showing soft, gradual change (shading, texture).
    public var gradientFraction: Double
    /// The significant colors, most common first, and their share of opaque pixels.
    public var palette: [RGBA]
    public var shares: [Double]
}

public struct ClassifierParams: Sendable, Equatable {
    public var alphaThreshold: UInt8 = 128
    public var mergeDistance: Double = 10
    public var minColorShare: Double = 0.001
    public var blendSlack: Double = 0.15
    public var blendKeepShare: Double = 0.03
    public var logoMaxColors = 32
    public var logoMaxGradientFraction = 0.25
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
        let gradient = gradientFraction(sample, alphaThreshold: p.alphaThreshold)
        let isLogo = palette.count <= p.logoMaxColors && gradient < p.logoMaxGradientFraction
        return Analysis(
            kind: isLogo ? .logo : .photo, significantColors: palette.count, gradientFraction: gradient,
            palette: palette.map(\.color), shares: palette.map { total > 0 ? Double($0.count) / Double(total) : 0 })
    }

    /// Nearest-neighbor downsample so the long side is at most `maxSide`.
    static func downsample(_ b: Bitmap, to maxSide: Int) -> Bitmap {
        let longSide = max(b.width, b.height)
        guard longSide > maxSide else { return b }
        let w = max(1, b.width * maxSide / longSide), h = max(1, b.height * maxSide / longSide)
        return Bitmap(width: w, height: h) { x, y in b[x * b.width / w, y * b.height / h] }
    }

    /// Share of opaque pixels whose 3×3 box-averaged color differs from the box 3 px to the
    /// right or below by 2.5…40 (largest channel). Averaging hides compression noise; the upper
    /// bound excludes hard edges. Flat logos score low; gradients and textures score high.
    static func gradientFraction(_ b: Bitmap, alphaThreshold: UInt8) -> Double {
        let w = b.width, h = b.height, d = 3
        guard w > 2 + d, h > 2 + d else { return 0 }
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
        var soft = 0, counted = 0
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
                if m >= 2.5 && m <= 40 { soft += 1 }
            }
        }
        return counted == 0 ? 0 : Double(soft) / Double(counted)
    }
}
