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
    static func build(_ t: Topology, params: PolygonParams) -> [PolyChain] {
        t.chains.map { build($0, params: params) }
    }

    static func build(_ chain: Chain, params p: PolygonParams) -> PolyChain {
        var dense = densePoints(chain, cornerRunLength: p.cornerRunLength)
        var vertices: [Int]
        if chain.isClosed {
            vertices = removeRedundant(simplifyClosed(dense, tolerance: p.tolerance), dense, tolerance: p.tolerance)
            if vertices.count < 3 { vertices = Array(dense.indices) }
        } else {
            vertices = simplify(Array(dense.indices), dense, tolerance: p.tolerance)
        }
        (dense, vertices) = sharpenCorners(dense, vertices, isClosed: chain.isClosed, cornerAngle: p.cornerAngle,
                                           straightTolerance: p.straightTolerance)
        let corners = classifyCorners(dense, vertices, isClosed: chain.isClosed, params: p)
        return PolyChain(dense: dense, vertices: vertices, corners: corners, isClosed: chain.isClosed)
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
        var out: [Vec2] = chain.isClosed ? [] : [pts[0].vec]
        for (k, r) in rs.enumerated() {
            let start = pts[r.start].vec, dir = Vec2(Double(r.dx), Double(r.dy))
            // A flat side: its neighbours step in opposite directions (unlike a staircase diagonal)
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
            if flat && prev!.length < cornerRunLength {
                out.append(start + dir * min(half - 0.5, 0.5 + 1.4 * Double(run(-2)?.length ?? 0)))
            }
            out.append(start + dir * half)
            if flat && next!.length < cornerRunLength {
                out.append(start + dir * (Double(r.length) - min(half - 0.5, 0.5 + 1.4 * Double(run(2)?.length ?? 0))))
            }
            if k == rs.count - 1 && !chain.isClosed { break }
            let following = rs[(k + 1) % rs.count]
            if r.length >= cornerRunLength && following.length >= cornerRunLength {
                out.append(pts[r.start + r.length].vec)
            }
        }
        if !chain.isClosed { out.append(pts[pts.count - 1].vec) }
        return out
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

    /// Drops ring vertices whose removal keeps every dense point within tolerance.
    static func removeRedundant(_ v: [Int], _ dense: [Vec2], tolerance: Double) -> [Int] {
        var v = v
        var j = 0
        while j < v.count && v.count > 3 {
            let prev = v[(j + v.count - 1) % v.count], next = v[(j + 1) % v.count]
            if maxDeviation(dense, from: prev, to: next) <= tolerance { v.remove(at: j) } else { j += 1 }
        }
        return v
    }

    /// Bevels shorter than this (px) are candidates for sharpening.
    static let cornerReach = 8.0

    /// Anti-aliasing and quantization shave sharp corners into a short bevel: two vertices a few
    /// pixels apart between two much longer edges. Replace such a pair with the intersection of
    /// those edges when it is close by and forms a real corner. Open-chain endpoints never move.
    static func sharpenCorners(_ dense: [Vec2], _ v: [Int], isClosed: Bool, cornerAngle: Double,
                               straightTolerance: Double) -> ([Vec2], [Int]) {
        var dense = dense, v = v
        var j = isClosed ? 0 : 1
        while true {
            let m = v.count
            guard m >= (isClosed ? 5 : 4) else { break }
            // Edge (j, j+1). Closed rings skip the wrap-around edge; open chains keep both ends fixed.
            if isClosed ? j >= m - 1 : j + 2 >= m { break }
            let a = dense[v[isClosed ? (j + m - 1) % m : j - 1]], b = dense[v[j]]
            let c = dense[v[j + 1]], d = dense[v[(j + 2) % m]]
            let bevel = b.distance(to: c)
            // A shaved corner is a straight cut; a small rounded corner bulges outward from it.
            if bevel < cornerReach, a.distance(to: b) >= 2.5 * bevel, c.distance(to: d) >= 2.5 * bevel,
               maxDeviation(dense, from: v[j], to: v[j + 1]) <= straightTolerance / 2,
               let x = intersection(a, b, d, c),
               x.distance(to: b) < cornerReach, x.distance(to: c) < cornerReach,
               turnDegrees(a, x, d) >= cornerAngle,
               // Anti-aliasing shaves acute corners noticeably but right angles barely; a longer
               // bevel on a right-angle-ish turn is a deliberately rounded corner.
               bevel <= 2.5 || turnDegrees(a, x, d) >= 100
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
