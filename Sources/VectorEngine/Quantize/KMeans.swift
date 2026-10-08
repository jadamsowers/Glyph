extension Quantizer {
    static func quantize(_ bitmap: Bitmap, params: QuantizeParams) -> QuantizedImage {
        if let mono = params.monochrome { return monochrome(bitmap, mono) }
        return switch params.kind {
        case .logo: logo(bitmap, params: params)
        case .photo: photo(bitmap, params: params)
        }
    }

    /// Deterministic k-means++ in Lab on an evenly strided pixel sample. Palette colors are the
    /// mean sRGB color of each cluster; duplicates are dropped so equal colors never split regions.
    static func photo(_ bitmap: Bitmap, params p: QuantizeParams) -> QuantizedImage {
        let opaque = bitmap.pixels.filter { $0.a >= p.alphaThreshold }
        guard !opaque.isEmpty else { return assign(bitmap, palette: [], alphaThreshold: p.alphaThreshold) }
        let step = max(1, opaque.count / max(1, p.kmeansSampleSize))
        let sample = stride(from: 0, to: opaque.count, by: step).map { opaque[$0] }
        let labs = sample.map { Lab($0) }
        let k = max(1, min(p.colorCount, Set(sample.map(\.rgbKey)).count))
        var rng = SplitMix64(seed: 0x5EED)

        var centers = [labs[Int(rng.next() % UInt64(labs.count))]]
        var nearest = labs.map { $0.distance(to: centers[0]) }
        while centers.count < k {
            let weights = nearest.map { $0 * $0 }
            let total = weights.reduce(0, +)
            guard total > 0 else { break }
            var target = Double(rng.next() % 1_000_000) / 1_000_000 * total
            var chosen = labs.count - 1
            for (i, w) in weights.enumerated() {
                target -= w
                if target <= 0 { chosen = i; break }
            }
            centers.append(labs[chosen])
            for i in labs.indices { nearest[i] = min(nearest[i], labs[i].distance(to: labs[chosen])) }
        }

        var colors = [RGBA](repeating: .clear, count: centers.count)
        for _ in 0..<max(1, p.kmeansIterations) {
            var sl = [Double](repeating: 0, count: centers.count), sa = sl, sb = sl
            var sr = [Int](repeating: 0, count: centers.count), sg = sr, sbl = sr, n = sr
            for (i, lab) in labs.enumerated() {
                var best = 0, bestD = Double.infinity
                for (j, c) in centers.enumerated() {
                    let d = c.distance(to: lab)
                    if d < bestD { bestD = d; best = j }
                }
                sl[best] += lab.l; sa[best] += lab.a; sb[best] += lab.b
                sr[best] += Int(sample[i].r); sg[best] += Int(sample[i].g); sbl[best] += Int(sample[i].b)
                n[best] += 1
            }
            for j in centers.indices where n[j] > 0 {
                let c = Double(n[j])
                centers[j] = Lab(l: sl[j] / c, a: sa[j] / c, b: sb[j] / c)
                colors[j] = RGBA(UInt8(sr[j] / n[j]), UInt8(sg[j] / n[j]), UInt8(sbl[j] / n[j]))
            }
        }
        var palette: [RGBA] = []
        for c in colors where c.a > 0 && !palette.contains(c) { palette.append(c) }
        return assign(bitmap, palette: palette, alphaThreshold: p.alphaThreshold)
    }
}
