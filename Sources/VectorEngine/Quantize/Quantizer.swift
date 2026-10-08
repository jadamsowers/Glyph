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
        return assign(bitmap, palette: chosen.map(\.color), alphaThreshold: p.alphaThreshold)
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
