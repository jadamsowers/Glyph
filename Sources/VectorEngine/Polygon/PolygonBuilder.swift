import Foundation

/// One chain's boundary as dense points plus the simplified polygon chosen from them.
public struct PolyChain: Sendable, Equatable {
    /// Boundary sample points. Open chains include both endpoints; closed chains don't repeat the first point.
    public var dense: [Vec2]
    /// Indices into `dense` of the polygon's vertices, ascending.
    public var vertices: [Int]
    /// Whether each polygon vertex is a sharp corner (open-chain endpoints always are).
    public var corners: [Bool]
    public var isClosed: Bool

    public var polygon: [Vec2] { vertices.map { dense[$0] } }
}

enum PolygonBuilder {
    /// `multipliers` (one per chain) scale the tolerance — see `Perceptual.toleranceMultiplier`.
    static func build(_ t: Topology, params: PolygonParams, multipliers: [Double]? = nil) -> [PolyChain] {
        t.chains.indices.map { i in
            var p = params
            if let m = multipliers?[i] { p.tolerance *= m }
            return build(t.chains[i], params: p)
        }
    }

    static func build(_ chain: Chain, params p: PolygonParams) -> PolyChain {
        if p.exactPixels { return exactPolygon(chain) }
        var (dense, protected) = samplePoints(chain, cornerRunLength: p.cornerRunLength, minFeatureArea: p.minFeatureArea)
        var vertices: [Int]
        if chain.isClosed {
            vertices = protected.isEmpty
                ? simplifyClosed(dense, tolerance: p.tolerance)
                : simplifyClosed(dense, anchors: protected.sorted(), tolerance: p.tolerance)
            vertices = removeRedundant(vertices, dense, tolerance: p.tolerance, keeping: protected)
            if vertices.count < 3 { vertices = Array(dense.indices) }
        } else {
            let anchors = Set([0, dense.count - 1]).union(protected).sorted()
            vertices = zip(anchors, anchors.dropFirst()).flatMap { a, b in simplify(Array(a...b), dense, tolerance: p.tolerance).dropLast() }
                + [dense.count - 1]
        }
        // Sharpening can shift indices, so protected vertices are tracked by position.
        let protectedPoints = Set(protected.map { dense[$0] })
        (dense, vertices) = sharpenCorners(dense, vertices, isClosed: chain.isClosed, cornerAngle: p.cornerAngle,
                                           straightTolerance: p.straightTolerance, unit: p.unit, keeping: protectedPoints)
        var corners = classifyCorners(dense, vertices, isClosed: chain.isClosed, params: p)
        for (k, v) in vertices.enumerated() where protectedPoints.contains(dense[v]) { corners[k] = true }
        return PolyChain(dense: dense, vertices: vertices, corners: corners, isClosed: chain.isClosed)
    }

    /// Pixel-exact outline: the chain's turn vertices, all corners.
    static func exactPolygon(_ chain: Chain) -> PolyChain {
        var pts = chain.points
        if chain.isClosed { pts.removeLast() }
        let m = pts.count
        var keep: [Int] = []
        for i in 0..<m {
            if !chain.isClosed && (i == 0 || i == m - 1) { keep.append(i); continue }
            let a = pts[(i + m - 1) % m], b = pts[i], c = pts[(i + 1) % m]
            if (b.x - a.x, b.y - a.y) != (c.x - b.x, c.y - b.y) { keep.append(i) }
        }
        let dense = keep.map { pts[$0].vec }
        return PolyChain(dense: dense, vertices: Array(dense.indices), corners: dense.map { _ in true }, isClosed: chain.isClosed)
    }

    struct Run {
        var start: Int
        var length: Int
        var dx: Int
        var dy: Int
    }

    /// Groups consecutive unit steps of a lattice path (≥ 2 points) into straight runs.
    static func runs(_ pts: [LatticePoint]) -> [Run] {
        var out: [Run] = []
        for i in 0..<(pts.count - 1) {
            let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y
            if let last = out.last, last.dx == dx, last.dy == dy {
                out[out.count - 1].length += 1
            } else {
                out.append(Run(start: i, length: 1, dx: dx, dy: dy))
            }
        }
        return out
    }

    /// Run midpoints (plus both ends of flat runs), and turn vertices between two long runs.
    /// Open chains keep exact endpoints.
    static func densePoints(_ chain: Chain, cornerRunLength: Int) -> [Vec2] {
        samplePoints(chain, cornerRunLength: cornerRunLength, minFeatureArea: nil).dense
    }

    /// `densePoints`, plus detection of real pixel-level features. A bump or notch on a straight
    /// edge is a run that steps out, runs, and steps back by the same depth onto the line it
    /// left, with base runs on both sides at least as long as itself. (A rasterized curve's flat
    /// top fails that: its neighboring runs are shorter.) Features with area ≥ `minFeatureArea`
    /// are sampled at their exact lattice corners, returned as `protected` indices that
    /// simplification must keep and that become corners.
    static func samplePoints(_ chain: Chain, cornerRunLength: Int, minFeatureArea: Int?) -> (dense: [Vec2], protected: Set<Int>) {
        var pts = chain.points
        if chain.isClosed {
            pts.removeLast()
            let m = pts.count
            func step(_ i: Int) -> (Int, Int) {
                let a = pts[i % m], b = pts[(i + 1) % m]
                return (b.x - a.x, b.y - a.y)
            }
            // Start at a turn so no run wraps around the end of the list.
            if let t = (0..<m).first(where: { step($0 + m - 1) != step($0) }) {
                pts = Array(pts[t...] + pts[..<t])
            }
            pts.append(pts[0])
        }
        let rs = runs(pts)
        func runAt(_ idx: Int) -> Run? {
            if chain.isClosed { return rs[((idx % rs.count) + rs.count) % rs.count] }
            return idx >= 0 && idx < rs.count ? rs[idx] : nil
        }
        func wrap(_ idx: Int) -> Int { ((idx % rs.count) + rs.count) % rs.count }
        // Roles: a feature's own run, and the steps out of and back into its base line.
        var isFeature = [Bool](repeating: false, count: rs.count)
        var stepOut = isFeature, stepIn = isFeature
        if let minArea = minFeatureArea, rs.count >= 5 {
            for k in rs.indices {
                guard let r = runAt(k), let out = runAt(k - 1), let back = runAt(k + 1),
                      let before = runAt(k - 2), let after = runAt(k + 2),
                      chain.isClosed || (k >= 2 && k + 2 < rs.count)
                else { continue }
                let returns = out.dx == -back.dx && out.dy == -back.dy && out.length == back.length
                let onLine = before.dx == r.dx && before.dy == r.dy && after.dx == r.dx && after.dy == r.dy
                let based = before.length >= r.length && after.length >= r.length
                // A curve's extreme looks the same up close, but its outline keeps stepping the
                // same way before the base runs and after them (short steps matching the step out
                // and the step back). A real bump's base line ends at a corner or runs on straight.
                var hump = false
                if let rise = runAt(k - 3), let fall = runAt(k + 3), chain.isClosed || (k >= 3 && k + 3 < rs.count) {
                    hump = rise.dx == out.dx && rise.dy == out.dy && rise.length <= 2 * out.length
                        && fall.dx == back.dx && fall.dy == back.dy && fall.length <= 2 * back.length
                }
                if returns && onLine && based && !hump && r.length * out.length >= max(1, minArea) {
                    isFeature[k] = true
                    stepOut[wrap(k - 1)] = true
                    stepIn[wrap(k + 1)] = true
                }
            }
        }
        var protected = Set<Int>()
        var out: [Vec2] = chain.isClosed ? [] : [pts[0].vec]
        func exact(_ v: Vec2) {
            if out.last != v { out.append(v) }
            protected.insert(out.count - 1)
        }
        for (k, r) in rs.enumerated() {
            let start = pts[r.start].vec, dir = Vec2(Double(r.dx), Double(r.dy))
            if isFeature[k] || stepOut[k] || stepIn[k] {
                if isFeature[k] || stepOut[k] { exact(start) }
                if isFeature[k] || stepIn[k] { exact(pts[r.start + r.length].vec) }
                continue
            }
            // A flat side: its neighbors step in opposite directions (unlike a staircase diagonal)
            // and it is much longer than the next parallel runs. A circle's flat top is only ~2.7×
            // longer than those at any radius, so it isn't mistaken for a side. Along a side the
            // true edge runs on the pixel boundary, so its ends are sampled too.
            func run(_ offset: Int) -> Run? {
                let idx = k + offset
                if chain.isClosed { return rs[((idx % rs.count) + rs.count) % rs.count] }
                return idx >= 0 && idx < rs.count ? rs[idx] : nil
            }
            let prev = run(-1), next = run(1)
            let parallel = max(run(-2)?.length ?? 0, run(2)?.length ?? 0)
            let flat = rs.count >= 4 && r.length >= 2 && Double(r.length) >= 3.5 * Double(parallel)
                && prev != nil && next != nil && prev!.dx == -next!.dx && prev!.dy == -next!.dy
            // Where a side runs into a rounded corner, the pixels stay flat for ~√R past the true
            // tangent point, about one parallel-run length (~0.73·√R) plus a little; inset the end
            // sample by that. Ends next to a long run already get an exact corner vertex below.
            let half = Double(r.length) / 2
            let nextIsFeatureStep = stepOut[wrap(k + 1)] && (chain.isClosed || k + 1 < rs.count)
            let prevIsFeatureStep = stepIn[wrap(k - 1)] && (chain.isClosed || k > 0)
            if flat && prev!.length < cornerRunLength && !prevIsFeatureStep {
                out.append(start + dir * min(half - 0.5, 0.5 + 1.4 * Double(run(-2)?.length ?? 0)))
            }
            out.append(start + dir * half)
            if flat && next!.length < cornerRunLength && !nextIsFeatureStep {
                out.append(start + dir * (Double(r.length) - min(half - 0.5, 0.5 + 1.4 * Double(run(2)?.length ?? 0))))
            }
            if k == rs.count - 1 && !chain.isClosed { break }
            let following = rs[(k + 1) % rs.count]
            if r.length >= cornerRunLength && following.length >= cornerRunLength && !stepOut[wrap(k + 1)] {
                out.append(pts[r.start + r.length].vec)
            }
        }
        if !chain.isClosed && out.last != pts[pts.count - 1].vec { out.append(pts[pts.count - 1].vec) }
        if chain.isClosed, out.count > 1, out.first == out.last {
            out.removeLast()
            if protected.contains(out.count) { protected.remove(out.count); protected.insert(0) }
        }
        return (out, protected)
    }

    /// Douglas–Peucker over `idx` (indices into `pts`); always keeps the first and last index.
    static func simplify(_ idx: [Int], _ pts: [Vec2], tolerance: Double) -> [Int] {
        guard idx.count > 2 else { return idx }
        var keep = [Bool](repeating: false, count: idx.count)
        keep[0] = true
        keep[idx.count - 1] = true
        var stack = [(0, idx.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = -1.0, at = a
            for i in (a + 1)..<b {
                let d = pts[idx[i]].distance(toSegment: pts[idx[a]], pts[idx[b]])
                if d > worst { worst = d; at = i }
            }
            if worst > tolerance {
                keep[at] = true
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        return idx.indices.filter { keep[$0] }.map { idx[$0] }
    }

    /// Douglas–Peucker on a ring: split at point 0 and the point farthest from it.
    static func simplifyClosed(_ pts: [Vec2], tolerance: Double) -> [Int] {
        let n = pts.count
        guard n > 3 else { return Array(0..<n) }
        let far = (1..<n).max { pts[$0].distance(to: pts[0]) < pts[$1].distance(to: pts[0]) }!
        let first = simplify(Array(0...far), pts, tolerance: tolerance)
        let second = simplify(Array(far..<n) + [0], pts, tolerance: tolerance)
        return first + second.dropFirst().dropLast()
    }

    /// Douglas–Peucker on a ring between fixed anchor indices (ascending), each kept.
    static func simplifyClosed(_ pts: [Vec2], anchors: [Int], tolerance: Double) -> [Int] {
        let n = pts.count
        var out: [Int] = []
        for (k, a) in anchors.enumerated() {
            let b = anchors[(k + 1) % anchors.count]
            let span = b > a ? Array(a...b) : Array(a..<n) + Array(0...b)
            out += simplify(span, pts, tolerance: tolerance).dropLast()
        }
        return Array(Set(out)).sorted()
    }

    /// Drops ring vertices whose removal keeps every dense point within tolerance.
    static func removeRedundant(_ v: [Int], _ dense: [Vec2], tolerance: Double, keeping: Set<Int> = []) -> [Int] {
        var v = v
        var j = 0
        while j < v.count && v.count > 3 {
            let prev = v[(j + v.count - 1) % v.count], next = v[(j + 1) % v.count]
            if !keeping.contains(v[j]) && maxDeviation(dense, from: prev, to: next) <= tolerance { v.remove(at: j) } else { j += 1 }
        }
        return v
    }

    /// Bevels shorter than this (px) are candidates for sharpening.
    static let cornerReach = 8.0

    /// Anti-aliasing and quantization shave sharp corners into a short bevel: two vertices a few
    /// pixels apart between two much longer edges. Replace such a pair with the intersection of
    /// those edges when it is close by and forms a real corner. Open-chain endpoints never move.
    static func sharpenCorners(_ dense: [Vec2], _ v: [Int], isClosed: Bool, cornerAngle: Double,
                               straightTolerance: Double, unit: Double = 1, keeping: Set<Vec2> = []) -> ([Vec2], [Int]) {
        let reach = cornerReach * unit
        var dense = dense, v = v
        var j = isClosed ? 0 : 1
        while true {
            let m = v.count
            guard m >= (isClosed ? 5 : 4) else { break }
            // Edge (j, j+1). Closed rings skip the wrap-around edge; open chains keep both ends fixed.
            if isClosed ? j >= m - 1 : j + 2 >= m { break }
            let a = dense[v[isClosed ? (j + m - 1) % m : j - 1]], b = dense[v[j]]
            let c = dense[v[j + 1]], d = dense[v[(j + 2) % m]]
            if keeping.contains(b) || keeping.contains(c) { j += 1; continue }
            let bevel = b.distance(to: c)
            // A shaved corner is a straight cut; a small rounded corner bulges outward from it.
            if bevel < reach, a.distance(to: b) >= 2.5 * bevel, c.distance(to: d) >= 2.5 * bevel,
               maxDeviation(dense, from: v[j], to: v[j + 1]) <= straightTolerance / 2,
               let x = intersection(a, b, d, c),
               x.distance(to: b) < reach, x.distance(to: c) < reach,
               turnDegrees(a, x, d) >= cornerAngle,
               // Anti-aliasing shaves acute corners noticeably but right angles barely; a longer
               // bevel on a right-angle-ish turn is a deliberately rounded corner.
               bevel <= 2.5 * unit || turnDegrees(a, x, d) >= 100
            {
                let lo = v[j], hi = v[j + 1]
                dense.replaceSubrange(lo...hi, with: [x])
                v.remove(at: j + 1)
                for k in (j + 1)..<v.count { v[k] -= hi - lo }
            } else {
                j += 1
            }
        }
        return (dense, v)
    }

    /// Where the line through a→b meets the line through d→c, unless they're parallel.
    static func intersection(_ a: Vec2, _ b: Vec2, _ d: Vec2, _ c: Vec2) -> Vec2? {
        let r = b - a, s = c - d
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-9 else { return nil }
        let t = ((d.x - a.x) * s.y - (d.y - a.y) * s.x) / denom
        return a + r * t
    }

    /// How far the path a → c → b turns at c, in degrees (0 = straight on).
    static func turnDegrees(_ a: Vec2, _ c: Vec2, _ b: Vec2) -> Double {
        acos(max(-1, min(1, (c - a).normalized.dot((b - c).normalized)))) * 180 / .pi
    }

    static func classifyCorners(_ dense: [Vec2], _ v: [Int], isClosed: Bool, params p: PolygonParams) -> [Bool] {
        let m = v.count
        return (0..<m).map { j in
            if !isClosed && (j == 0 || j == m - 1) { return true }
            let prev = (j + m - 1) % m, next = (j + 1) % m
            let turn = turnDegrees(dense[v[prev]], dense[v[j]], dense[v[next]])
            if turn >= 150 { return true }
            guard turn >= p.cornerAngle else { return false }
            return isStraight(dense, v[prev], v[j], p) || isStraight(dense, v[j], v[next], p)
        }
    }

    /// An edge is straight if its points bulge less than `straightTolerance` or 5% of its length.
    /// (An arc turning by `cornerAngle` or more bulges by at least ~12% of its chord, so arcs fail.)
    static func isStraight(_ dense: [Vec2], _ i: Int, _ j: Int, _ p: PolygonParams) -> Bool {
        maxDeviation(dense, from: i, to: j) <= max(p.straightTolerance, 0.05 * dense[i].distance(to: dense[j]))
    }

    /// Largest distance from the dense points strictly between i and j (walking forward, wrapping)
    /// to the chord i–j.
    static func maxDeviation(_ dense: [Vec2], from i: Int, to j: Int) -> Double {
        let n = dense.count
        var worst = 0.0, k = (i + 1) % n
        while k != j {
            worst = max(worst, dense[k].distance(toSegment: dense[i], dense[j]))
            k = (k + 1) % n
        }
        return worst
    }
}
