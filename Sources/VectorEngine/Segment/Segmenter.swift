public struct Region: Sendable, Equatable {
    public var color: RGBA
    public var pixelCount: Int
}

/// Connected regions (4-connectivity) of equal palette color.
public struct Segmentation: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Region label per pixel; -1 = transparent.
    public let labels: [Int32]
    public let regions: [Region]

    /// The label at (x, y), or -1 outside the image.
    @inline(__always)
    public func label(_ x: Int, _ y: Int) -> Int32 {
        x < 0 || y < 0 || x >= width || y >= height ? -1 : labels[y * width + x]
    }
}

public struct SegmentParams: Sendable, Equatable {
    /// Regions with fewer pixels than this are merged into their most similar neighbor.
    public var speckSize: Int
    /// When set, a speck whose color is close to its most similar neighbour (ΔE below this) may be
    /// up to 4× larger and still merge — faint specks are invisible at sizes where vivid ones aren't.
    public var contrastReference: Double? = nil

    public init(speckSize: Int) { self.speckSize = speckSize }
}

enum Segmenter {
    static func segment(_ q: QuantizedImage, params: SegmentParams) -> Segmentation {
        let (labels, colorOf, counts) = labelComponents(q)
        return mergeSpecks(q, labels: labels, colorOf: colorOf, counts: counts, speckSize: params.speckSize,
                           contrastReference: params.contrastReference)
    }

    /// Flood-fills runs of equal palette index with an explicit stack (no recursion).
    static func labelComponents(_ q: QuantizedImage) -> (labels: [Int32], colorOf: [Int32], counts: [Int]) {
        let w = q.width, h = q.height
        var labels = [Int32](repeating: -1, count: w * h)
        var colorOf: [Int32] = [], counts: [Int] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where q.indices[start] >= 0 && labels[start] < 0 {
            let id = Int32(colorOf.count), color = q.indices[start]
            colorOf.append(color)
            var n = 0
            labels[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                n += 1
                let x = i % w, y = i / w
                if x > 0, labels[i - 1] < 0, q.indices[i - 1] == color { labels[i - 1] = id; stack.append(i - 1) }
                if x < w - 1, labels[i + 1] < 0, q.indices[i + 1] == color { labels[i + 1] = id; stack.append(i + 1) }
                if y > 0, labels[i - w] < 0, q.indices[i - w] == color { labels[i - w] = id; stack.append(i - w) }
                if y < h - 1, labels[i + w] < 0, q.indices[i + w] == color { labels[i + w] = id; stack.append(i + w) }
            }
            counts.append(n)
        }
        return (labels, colorOf, counts)
    }

    /// Merges regions smaller than `speckSize` (smallest first) into the adjacent region with the
    /// closest Lab color (ties: longer shared border, then lower label), using a region adjacency
    /// graph and union-find. Regions touching only transparency are kept. Labels are then renumbered
    /// in order of first appearance.
    static func mergeSpecks(_ q: QuantizedImage, labels: [Int32], colorOf: [Int32], counts: [Int], speckSize: Int,
                            contrastReference: Double? = nil) -> Segmentation {
        let w = q.width, h = q.height, n = counts.count
        var parent = Array(0..<n)
        var size = counts
        if speckSize > 1 && n > 1 {
            var adj = [[Int: Int]](repeating: [:], count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let a = Int(labels[y * w + x])
                    guard a >= 0 else { continue }
                    if x + 1 < w {
                        let b = Int(labels[y * w + x + 1])
                        if b >= 0 && b != a { adj[a][b, default: 0] += 1; adj[b][a, default: 0] += 1 }
                    }
                    if y + 1 < h {
                        let b = Int(labels[(y + 1) * w + x])
                        if b >= 0 && b != a { adj[a][b, default: 0] += 1; adj[b][a, default: 0] += 1 }
                    }
                }
            }
            let labs = q.palette.map { Lab($0) }
            let maxBoost = contrastReference == nil ? 1 : 4
            let order = (0..<n).filter { counts[$0] < speckSize * maxBoost }.sorted { (counts[$0], $0) < (counts[$1], $1) }
            for r in order {
                // Adjacency keys are always current roots, so `r` is still a root unless merged away.
                guard parent[r] == r, size[r] < speckSize * maxBoost, !adj[r].isEmpty else { continue }
                let mine = labs[Int(colorOf[r])]
                let target = adj[r].min { l, m in
                    let dl = labs[Int(colorOf[l.key])].distance(to: mine), dm = labs[Int(colorOf[m.key])].distance(to: mine)
                    if dl != dm { return dl < dm }
                    if l.value != m.value { return l.value > m.value }
                    return l.key < m.key
                }!.key
                if let ref = contrastReference {
                    let d = labs[Int(colorOf[target])].distance(to: mine)
                    guard Double(size[r]) < Double(speckSize) * min(4, max(1, ref / max(d, 1e-6))) else { continue }
                } else if size[r] >= speckSize { continue }
                parent[r] = target
                size[target] += size[r]
                for (nb, len) in adj[r] where nb != target {
                    adj[nb][r] = nil
                    adj[nb][target, default: 0] += len
                    adj[target][nb, default: 0] += len
                }
                adj[target][r] = nil
                adj[r] = [:]
            }
        }
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var newId = [Int32](repeating: -1, count: n)
        var regions: [Region] = []
        var out = [Int32](repeating: -1, count: w * h)
        for i in 0..<(w * h) {
            let l = Int(labels[i])
            guard l >= 0 else { continue }
            let root = find(l)
            if newId[root] < 0 {
                newId[root] = Int32(regions.count)
                regions.append(Region(color: q.palette[Int(colorOf[root])], pixelCount: size[root]))
            }
            out[i] = newId[root]
        }
        return Segmentation(width: w, height: h, labels: out, regions: regions)
    }
}
