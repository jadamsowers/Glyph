/// A group of perceptually similar colors found in an image.
struct ColorCluster: Sendable, Equatable {
    var color: RGBA
    var lab: Lab
    var count: Int
    /// Pixels whose four neighbours share their (5-bit) color: interior of a flat area. Anti-alias
    /// blends live in thin bands and have almost none.
    var flatCount: Int = 0
}

enum PaletteBuilder {
    /// Buckets opaque pixels (5 bits per channel), then greedily merges buckets, most
    /// frequent first, into clusters whose seed is within `mergeDistance` (Lab).
    /// Cluster colors are count-weighted means. Sorted by count, descending.
    static func clusters(of bitmap: Bitmap, alphaThreshold: UInt8, mergeDistance: Double, maxClusters: Int = 256)
        -> (clusters: [ColorCluster], opaqueCount: Int)
    {
        var sums: [Int: (r: Int, g: Int, b: Int, n: Int, flat: Int)] = [:]
        var opaque = 0
        let w = bitmap.width, h = bitmap.height
        let keys = bitmap.pixels.map { p in p.a >= alphaThreshold ? Int(p.r >> 3) << 10 | Int(p.g >> 3) << 5 | Int(p.b >> 3) : -1 }
        for (i, p) in bitmap.pixels.enumerated() where p.a >= alphaThreshold {
            opaque += 1
            let key = keys[i], x = i % w, y = i / w
            let flat = x > 0 && x < w - 1 && y > 0 && y < h - 1
                && keys[i - 1] == key && keys[i + 1] == key && keys[i - w] == key && keys[i + w] == key
            var s = sums[key] ?? (0, 0, 0, 0, 0)
            s.r += Int(p.r); s.g += Int(p.g); s.b += Int(p.b); s.n += 1
            if flat { s.flat += 1 }
            sums[key] = s
        }
        let buckets = sums.values
            .map { s in (color: RGBA(UInt8(s.r / s.n), UInt8(s.g / s.n), UInt8(s.b / s.n)), n: s.n, flat: s.flat) }
            .sorted { $0.n != $1.n ? $0.n > $1.n : $0.color.rgbKey < $1.color.rgbKey }

        struct Acc { var seed: Lab; var r = 0, g = 0, b = 0, n = 0, flat = 0 }
        var accs: [Acc] = []
        // A bucket that is mostly flat interior pixels is a real color even when close to another
        // (subtle UI grays); merging near colors is for noise, which never forms flat areas.
        let minFlat = max(16, opaque / 2000)
        for bucket in buckets {
            let lab = Lab(bucket.color)
            var target = -1, best = Double.infinity
            for (i, acc) in accs.enumerated() {
                let d = acc.seed.distance(to: lab)
                if d < best { best = d; target = i }
            }
            let distinctFlat = bucket.flat * 2 >= bucket.n && bucket.flat >= minFlat && best >= 2
            if target < 0 || best >= mergeDistance || distinctFlat {
                guard accs.count < maxClusters else { continue }
                accs.append(Acc(seed: lab))
                target = accs.count - 1
            }
            accs[target].r += Int(bucket.color.r) * bucket.n
            accs[target].g += Int(bucket.color.g) * bucket.n
            accs[target].b += Int(bucket.color.b) * bucket.n
            accs[target].n += bucket.n
            accs[target].flat += bucket.flat
        }
        let clusters = accs.map { a in
            let c = RGBA(UInt8(a.r / a.n), UInt8(a.g / a.n), UInt8(a.b / a.n))
            return ColorCluster(color: c, lab: Lab(c), count: a.n, flatCount: a.flat)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.color.rgbKey < $1.color.rgbKey }
        return (clusters, opaque)
    }

    /// Picks palette colors from clusters (most frequent first). Clusters under `minShare`
    /// are ignored; clusters under `blendKeepShare` that look like a mix of two already-chosen
    /// colors, and lack flat interior pixels, are treated as anti-aliasing or compression fringes
    /// and skipped.
    static func palette(from clusters: [ColorCluster], total: Int, maxColors: Int, minShare: Double,
                        blendSlack: Double, blendKeepShare: Double) -> [ColorCluster]
    {
        guard total > 0 else { return [] }
        var chosen: [ColorCluster] = []
        var shades: [ColorCluster] = []   // near-duplicates of a chosen color, considered last
        for c in clusters {
            if chosen.count >= maxColors { break }
            let share = Double(c.count) / Double(total)
            if share < minShare { break }
            // A small color on a blend line is anti-aliasing unless it has flat interior pixels
            // (a gray panel between black and white is real; the gray fringe around text isn't).
            let mostlyFlat = c.flatCount * 3 >= c.count
            if share < blendKeepShare && !mostlyFlat && isBlend(c.color, of: chosen, slack: blendSlack) { continue }
            // Perceptually distinct colors first: a second shade of blue must not take the slot
            // of a less common red.
            if chosen.contains(where: { $0.lab.distance(to: c.lab) < distinctDistance }) { shades.append(c); continue }
            chosen.append(c)
        }
        for c in shades where chosen.count < maxColors { chosen.append(c) }
        if chosen.isEmpty, let first = clusters.first { chosen = [first] }
        return chosen
    }

    /// Colors closer than this (ΔE) to an already-chosen one are shades, chosen after distinct colors.
    static let distinctDistance = 15.0

    /// Whether `c` looks like a mix of two of `colors`: the RGB path a → c → b is at most
    /// (1 + slack) times the direct distance a → b. The slack scales with the colors' separation,
    /// so it also catches JPEG chroma fringes that sit off the straight blend line.
    static func isBlend(_ c: RGBA, of colors: [ColorCluster], slack: Double) -> Bool {
        func dist(_ x: RGBA, _ y: RGBA) -> Double {
            let dr = Double(x.r) - Double(y.r), dg = Double(x.g) - Double(y.g), db = Double(x.b) - Double(y.b)
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        for i in colors.indices {
            for j in colors.indices where j > i {
                let a = colors[i].color, b = colors[j].color
                let direct = dist(a, b)
                if direct > 0 && dist(a, c) + dist(c, b) <= direct * (1 + slack) { return true }
            }
        }
        return false
    }
}
