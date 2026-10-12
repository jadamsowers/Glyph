import Foundation

/// Budgeted, perceptual reduction of fitted curves (the "Simplify" control). Repeatedly merges
/// the adjacent pair of segments, within a chain, whose replacement by one cubic costs least,
/// until the cheapest merge exceeds the budget set by `simplify`. The cost is how far the
/// outline moves, in display pixels — the eye judges displacement, so a small glyph is not cheap
/// just because its area is — times the boundary's visibility (contrast), plus a penalty for
/// removing a sharp corner. Only interior anchors are removed, so chain endpoints (junctions
/// shared with neighbors) never move and shared-edge output stays gap-free.
enum Simplifier {
    /// Largest accepted merge cost (display px of displacement) for a Simplify level in 0…1.
    static func budget(_ simplify: Double) -> Double { 2.5 * pow(simplify, 1.5) }
    /// Extra cost (display px) for removing an anchor where the outline turns by more than 25°.
    static let cornerPenalty = 1.0

    /// `bounds` is the processing image size: anchors on the image border only go if the merged
    /// curve stays on that border line (nothing paints outside the image, so a cut corner is a gap).
    static func reduce(_ curves: [Curve], visibility: [Double], params p: CurveParams, bounds: (width: Int, height: Int)? = nil) -> [Curve] {
        guard p.simplify > 0 else { return curves }
        let limit = budget(p.simplify)
        // Every outline piece goes in a spatial grid, so a merge whose new curve would cross another
        // boundary (or its own) is rejected: topology — and with it gap-free coverage — is kept.
        let grid = PieceGrid()
        var pieceIDs: [[[Int]]] = curves.indices.map { c in
            var cur = curves[c].start
            return curves[c].segments.map { seg in
                defer { cur = seg.end }
                return grid.insert(sample(cur, seg), owner: c)
            }
        }
        var out = curves
        for c in curves.indices {
            out[c] = reduce(curves[c], weight: visibility[c], limit: limit, displayScale: p.displayScale,
                            grid: grid, owner: c, pieceIDs: &pieceIDs[c], bounds: bounds)
        }
        return out
    }

    static func reduce(_ curve: Curve, weight: Double, limit: Double, displayScale: Double,
                       grid: PieceGrid, owner: Int, pieceIDs: inout [[Int]], bounds: (width: Int, height: Int)? = nil) -> Curve {
        func borderLines(_ v: Vec2) -> [(axis: Int, value: Double)] {
            guard let bounds else { return [] }
            var lines: [(Int, Double)] = []
            for (axis, value) in [(0, 0.0), (0, Double(bounds.width)), (1, 0.0), (1, Double(bounds.height))]
            where abs((axis == 0 ? v.x : v.y) - value) < 1e-6 { lines.append((axis, value)) }
            return lines
        }
        /// A merge removing the anchor `anchor` keeps the border if every border line through the
        /// anchor still holds every point of the merged curve.
        func keepsBorder(_ anchor: Vec2, _ points: [Vec2]) -> Bool {
            borderLines(anchor).allSatisfy { line in points.allSatisfy { abs((line.axis == 0 ? $0.x : $0.y) - line.value) < 1e-6 } }
        }
        var segs = curve.segments
        guard segs.count >= 2 else { return curve }
        func start(_ k: Int) -> Vec2 { k == 0 ? curve.start : segs[k - 1].end }
        func cost(_ k: Int) -> (Double, PathSegment) {
            let (merged, displacement) = merge(start(k), segs[k], segs[k + 1])
            let turn = acos(max(-1, min(1, (-endTangent(start(k), segs[k])).dot(startTangent(segs[k].end, segs[k + 1]))))) * 180 / .pi
            return (weight * (displacement * displayScale + (turn > 25 ? cornerPenalty : 0)), merged)
        }
        var costs = (0..<(segs.count - 1)).map(cost)
        var rejected = Set<Int>()   // merges blocked by a crossing (positions shift, so re-checked lazily)
        while let best = costs.indices.filter({ !rejected.contains($0) }).min(by: { costs[$0].0 < costs[$1].0 }),
              costs[best].0 <= limit
        {
            let p0 = start(best), merged = costs[best].1
            let points = sample(p0, merged)
            let ignore = Set(pieceIDs[best] + pieceIDs[best + 1])
            if !keepsBorder(segs[best].end, points) || grid.crosses(points, ignoring: ignore, endpoints: [p0, merged.end]) {
                rejected.insert(best)
                continue
            }
            grid.remove(ignore)
            segs[best] = merged
            segs.remove(at: best + 1)
            pieceIDs[best] = grid.insert(points, owner: owner)
            pieceIDs.remove(at: best + 1)
            costs.remove(at: best)
            rejected = Set(rejected.compactMap { $0 < best ? $0 : ($0 > best + 1 ? $0 - 1 : nil) })
            if best < costs.count { costs[best] = cost(best); rejected.remove(best) }
            if best > 0 { costs[best - 1] = cost(best - 1); rejected.remove(best - 1) }
        }
        return Curve(start: curve.start, segments: segs)
    }

    /// One segment replacing `a` then `b` (starting at `p0`), keeping the outer tangents, and the
    /// largest distance (processing px) from the old outline to the new one.
    static func merge(_ p0: Vec2, _ a: PathSegment, _ b: PathSegment) -> (PathSegment, Double) {
        let samples = sample(p0, a) + sample(a.end, b).dropFirst()
        let end = b.end
        let chord = end - p0
        let replacement: PathSegment
        if samples.allSatisfy({ $0.distance(toSegment: p0, end) < 1e-3 }) || chord.length < 1e-9 {
            replacement = .line(to: end)
        } else {
            replacement = BezierFit.single(Array(samples), leftTangent: startTangent(p0, a), rightTangent: endTangent(a.end, b))
        }
        let newPoints = sample(p0, replacement, count: 48)
        let maxDistance = samples.map { q in
            zip(newPoints, newPoints.dropFirst()).map { q.distance(toSegment: $0.0, $0.1) }.min()!
        }.max()!
        return (replacement, maxDistance)
    }

    static func sample(_ p0: Vec2, _ s: PathSegment, count: Int = 16) -> [Vec2] {
        switch s {
        case .line(let to): return (0...count).map { p0 + (to - p0) * (Double($0) / Double(count)) }
        case .cubic(let c1, let c2, let to): return (0...count).map { BezierFit.point([p0, c1, c2, to], Double($0) / Double(count)) }
        }
    }

    /// Direction leaving p0 along `s`.
    static func startTangent(_ p0: Vec2, _ s: PathSegment) -> Vec2 {
        if case .cubic(let c1, _, let to) = s { return ((c1 - p0).length > 1e-9 ? c1 - p0 : to - p0).normalized }
        return (s.end - p0).normalized
    }

    /// Direction from the end of `s` (which starts at p0) back into it.
    static func endTangent(_ p0: Vec2, _ s: PathSegment) -> Vec2 {
        if case .cubic(_, let c2, let to) = s { return ((c2 - to).length > 1e-9 ? c2 - to : p0 - to).normalized }
        return (p0 - s.end).normalized
    }
}

/// Line pieces of sampled outlines in a uniform grid, for crossing tests.
final class PieceGrid {
    private var pieces: [(a: Vec2, b: Vec2, alive: Bool)] = []
    private var cells: [Int64: [Int]] = [:]
    private let size = 4.0

    private func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }

    private func cellsTouched(_ a: Vec2, _ b: Vec2) -> [Int64] {
        let x0 = Int((min(a.x, b.x) / size).rounded(.down)), x1 = Int((max(a.x, b.x) / size).rounded(.down))
        let y0 = Int((min(a.y, b.y) / size).rounded(.down)), y1 = Int((max(a.y, b.y) / size).rounded(.down))
        var out: [Int64] = []
        for x in x0...x1 { for y in y0...y1 { out.append(key(x, y)) } }
        return out
    }

    /// Adds the polyline's pieces; returns their ids.
    func insert(_ points: [Vec2], owner: Int) -> [Int] {
        zip(points, points.dropFirst()).map { a, b in
            let id = pieces.count
            pieces.append((a, b, true))
            for k in cellsTouched(a, b) { cells[k, default: []].append(id) }
            return id
        }
    }

    func remove(_ ids: Set<Int>) { for id in ids { pieces[id].alive = false } }

    /// Whether the polyline properly crosses any live piece not in `ignoring`. Touching at one of
    /// `endpoints` (shared junctions) doesn't count.
    func crosses(_ points: [Vec2], ignoring: Set<Int>, endpoints: [Vec2]) -> Bool {
        for (a, b) in zip(points, points.dropFirst()) {
            var seen = Set<Int>()
            for k in cellsTouched(a, b) {
                for id in cells[k] ?? [] where pieces[id].alive && !ignoring.contains(id) && seen.insert(id).inserted {
                    let p = pieces[id]
                    if Self.properlyIntersect(a, b, p.a, p.b, except: endpoints) { return true }
                }
            }
        }
        return false
    }

    static func properlyIntersect(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2, except: [Vec2]) -> Bool {
        func cross(_ o: Vec2, _ p: Vec2, _ q: Vec2) -> Double { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        guard ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) else { return false }
        // Intersection point; ignore crossings at a shared endpoint.
        let t = d1 / (d1 - d2)
        let x = a + (b - a) * t
        return !except.contains { $0.distance(to: x) < 1e-6 }
    }
}
