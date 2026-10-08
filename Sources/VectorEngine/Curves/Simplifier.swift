import Foundation

/// Budgeted, perceptual reduction of fitted curves (the "Simplify" control). Repeatedly merges
/// the adjacent pair of segments, within a chain, whose replacement by one cubic costs least —
/// cost = area between old and new outline in display pixels × the boundary's visibility
/// (contrast) — until the cheapest merge exceeds the budget set by `simplify`. Only interior
/// anchors are removed, so chain endpoints (junctions shared with neighbours) never move and
/// shared-edge output stays gap-free.
enum Simplifier {
    /// Largest accepted merge cost (display px²) for a Simplify level in 0…1.
    static func budget(_ simplify: Double) -> Double { 12 * simplify * simplify }

    static func reduce(_ curves: [Curve], visibility: [Double], params p: CurveParams) -> [Curve] {
        guard p.simplify > 0 else { return curves }
        let limit = budget(p.simplify)
        return curves.indices.map { reduce(curves[$0], weight: visibility[$0], limit: limit, displayScale: p.displayScale) }
    }

    static func reduce(_ curve: Curve, weight: Double, limit: Double, displayScale: Double) -> Curve {
        var segs = curve.segments
        guard segs.count >= 2 else { return curve }
        func start(_ k: Int) -> Vec2 { k == 0 ? curve.start : segs[k - 1].end }
        func cost(_ k: Int) -> (Double, PathSegment) {
            let (merged, area) = merge(start(k), segs[k], segs[k + 1])
            return (weight * area * displayScale * displayScale, merged)
        }
        var costs = (0..<(segs.count - 1)).map(cost)
        while let best = costs.indices.min(by: { costs[$0].0 < costs[$1].0 }), costs[best].0 <= limit {
            segs[best] = costs[best].1
            segs.remove(at: best + 1)
            costs.remove(at: best)
            if best < costs.count { costs[best] = cost(best) }
            if best > 0 { costs[best - 1] = cost(best - 1) }
        }
        return Curve(start: curve.start, segments: segs)
    }

    /// One segment replacing `a` then `b` (starting at `p0`), keeping the outer tangents, and the
    /// area (processing px²) between the two outlines.
    static func merge(_ p0: Vec2, _ a: PathSegment, _ b: PathSegment) -> (PathSegment, Double) {
        let samples = sample(p0, a) + sample(a.end, b).dropFirst()
        let end = b.end
        let chord = end - p0
        let length = zip(samples, samples.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let replacement: PathSegment
        if samples.allSatisfy({ $0.distance(toSegment: p0, end) < 1e-3 }) || chord.length < 1e-9 {
            replacement = .line(to: end)
        } else {
            replacement = BezierFit.single(Array(samples), leftTangent: startTangent(p0, a), rightTangent: endTangent(a.end, b))
        }
        let newPoints = sample(p0, replacement, count: 48)
        let meanDistance = samples.reduce(0) { sum, q in
            sum + zip(newPoints, newPoints.dropFirst()).map { q.distance(toSegment: $0.0, $0.1) }.min()!
        } / Double(samples.count)
        return (replacement, meanDistance * length)
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
