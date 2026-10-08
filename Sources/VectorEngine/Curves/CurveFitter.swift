import Foundation

enum CurveFitter {
    static func fit(_ polys: [PolyChain], params: CurveParams) -> [Curve] {
        polys.map { fit($0, params: params) }
    }

    /// Breaks the chain at corners (and open ends) and fits each span: spans that are a single
    /// polygon edge, or whose points stay within `straightTolerance` of the chord, become one line;
    /// the rest become Bézier cubics. Closed loops with < 2 corners get smooth joins added so no
    /// span starts and ends at the same point.
    static func fit(_ poly: PolyChain, params p: CurveParams) -> Curve {
        let dense = poly.dense, n = dense.count, v = poly.vertices
        var breaks = zip(v, poly.corners).filter(\.1).map(\.0)
        var smooth = Set<Int>()
        if poly.isClosed && breaks.count < 2 {
            let anchor = breaks.first.flatMap { b in v.firstIndex(of: b) } ?? 0
            let joins = breaks.isEmpty ? [v[0], v[v.count / 2]] : [v[(anchor + v.count / 2) % v.count]]
            smooth = Set(joins)
            breaks = (breaks + joins).sorted()
        }

        func central(_ i: Int) -> Vec2 { (dense[(i + 2) % n] - dense[(i - 2 + n) % n]).normalized }

        var spans: [(Int, Int)] = []
        for i in 0..<(breaks.count - 1) { spans.append((breaks[i], breaks[i + 1])) }
        if poly.isClosed { spans.append((breaks[breaks.count - 1], breaks[0])) }

        let vertexSet = Set(v)
        var segments: [PathSegment] = []
        for (a, b) in spans {
            var pts: [Vec2] = []
            var interiorVertex = false
            var k = a
            while true {
                pts.append(dense[k])
                if k == b && pts.count > 1 { break }
                if pts.count > 1 && vertexSet.contains(k) { interiorVertex = true }
                k = (k + 1) % n
            }
            // A span that is a single polygon edge was already judged straight by the polygon stage.
            if !interiorVertex { segments.append(.line(to: dense[b])); continue }
            let start = smooth.contains(a) ? central(a) : forward(pts)
            let end = smooth.contains(b) ? -central(b) : backward(pts)
            segments += fitSpan(pts, startTangent: start, endTangent: end, params: p)
        }
        return Curve(start: dense[breaks[0]], segments: segments)
    }

    /// Fits one span between breaks. Long straight runs inside it become lines (their interior
    /// endpoints snapped onto the best-fit line); the curved pieces between them are Bézier-fitted
    /// with tangents that meet each line smoothly. The span's own endpoints never move.
    static func fitSpan(_ points: [Vec2], startTangent: Vec2, endTangent: Vec2, params p: CurveParams) -> [PathSegment] {
        let a = points[0], b = points[points.count - 1]
        if points.count == 2 || points.dropFirst().dropLast().allSatisfy({ $0.distance(toSegment: a, b) <= p.straightTolerance }) {
            return [.line(to: b)]
        }
        var pts = points
        var out: [PathSegment] = []
        var cursor = 0, cursorTangent = startTangent
        for run in straightRuns(pts, tolerance: p.straightTolerance) {
            let (center, direction) = lineFit(pts, run.lowerBound, run.upperBound)
            func project(_ v: Vec2) -> Vec2 { center + direction * (v - center).dot(direction) }
            if run.lowerBound > 0 { pts[run.lowerBound] = project(pts[run.lowerBound]) }
            if run.upperBound < pts.count - 1 { pts[run.upperBound] = project(pts[run.upperBound]) }
            if run.lowerBound > cursor {
                out += fitPiece(Array(pts[cursor...run.lowerBound]), cursorTangent, -direction, p)
            }
            out.append(.line(to: pts[run.upperBound]))
            cursor = run.upperBound
            cursorTangent = direction
        }
        if cursor < pts.count - 1 {
            out += fitPiece(Array(pts[cursor...]), cursorTangent, endTangent, p)
        }
        return out
    }

    /// A curved piece between known tangents: a single circular-arc fillet when it fits the points
    /// within tolerance (crisp rounded corners from few samples), else least-squares Béziers.
    static func fitPiece(_ pts: [Vec2], _ t1: Vec2, _ t2: Vec2, _ p: CurveParams) -> [PathSegment] {
        if let fillet = fillet(from: pts[0], t1, to: pts[pts.count - 1], t2),
           pts.allSatisfy({ distance($0, to: fillet, from: pts[0]) <= p.tolerance })
        {
            return [fillet]
        }
        return BezierFit.fit(pts, leftTangent: t1, rightTangent: t2, tolerance: p.tolerance)
    }

    /// The cubic approximating a circular arc that leaves `a` along `t1` and arrives at `b` coming
    /// from direction `-t2`: handles sit on the tangent lines at (4/3)·tan(θ/4)/tan(θ/2) of each
    /// leg, θ being the turn. Nil if the tangent lines don't meet ahead of both points.
    static func fillet(from a: Vec2, _ t1: Vec2, to b: Vec2, _ t2: Vec2) -> PathSegment? {
        let denom = t1.x * t2.y - t1.y * t2.x
        guard abs(denom) > 1e-6 else { return nil }
        // Solve a + t1·u = b + t2·v.
        let u = ((b.x - a.x) * t2.y - (b.y - a.y) * t2.x) / denom
        let v = ((b.x - a.x) * t1.y - (b.y - a.y) * t1.x) / denom
        guard u > 0, v > 0 else { return nil }
        let turn = acos(max(-1, min(1, t1.dot(-t2))))
        guard turn > 1e-3, turn < .pi * 0.95 else { return nil }
        let k = 4.0 / 3.0 * tan(turn / 4) / tan(turn / 2)
        return .cubic(c1: a + t1 * (u * k), c2: b + t2 * (v * k), to: b)
    }

    /// Distance from `q` to a cubic segment starting at `start`, by dense sampling.
    static func distance(_ q: Vec2, to seg: PathSegment, from start: Vec2) -> Double {
        guard case .cubic(let c1, let c2, let end) = seg else { return q.distance(toSegment: start, seg.end) }
        var best = Double.infinity, prev = start
        for i in 1...48 {
            let pt = BezierFit.point([start, c1, c2, end], Double(i) / 48)
            best = min(best, q.distance(toSegment: prev, pt))
            prev = pt
        }
        return best
    }

    /// Exactly collinear runs (pixel-aligned sides) at least this long (px) become lines.
    static let minExactLineLength = 12.0
    /// Runs with pixel jitter must be at least this long (px): an arc stays within a third of the
    /// tolerance over this length only if its radius is ≳ 240 px, and then joins smoothly anyway.
    static let minLineLength = 24.0

    /// Stretches of points that lie on a line. Candidates are maximal runs within `tolerance` of
    /// their chord, trimmed of ends that leak into neighbouring arcs; a run is kept if every point
    /// is within tolerance / 3 of its best-fit line and it is long enough (see above). Longest
    /// runs are taken first so a run can't cut across a side. Ascending, sharing at most endpoints.
    static func straightRuns(_ pts: [Vec2], tolerance: Double) -> [ClosedRange<Int>] {
        let n = pts.count
        guard n >= 3 else { return [] }
        func fits(_ i: Int, _ k: Int) -> Bool {
            k <= i + 1 || (i + 1..<k).allSatisfy { pts[$0].distance(toSegment: pts[i], pts[k]) <= tolerance }
        }
        var candidates: [ClosedRange<Int>] = []
        var j = 1
        for i in 0..<(n - 1) {
            j = max(j, i + 1)
            while j > i + 1 && !fits(i, j) { j -= 1 }
            while j + 1 < n && fits(i, j + 1) { j += 1 }
            if pts[i].distance(to: pts[j]) >= minExactLineLength, let run = trim(i...j, pts, tolerance: tolerance) {
                candidates.append(run)
            }
        }
        func length(_ r: ClosedRange<Int>) -> Double { pts[r.lowerBound].distance(to: pts[r.upperBound]) }
        var accepted: [ClosedRange<Int>] = []
        for c in candidates.sorted(by: { length($0) > length($1) }) where accepted.allSatisfy({ c.lowerBound >= $0.upperBound || c.upperBound <= $0.lowerBound }) {
            accepted.append(c)
        }
        return accepted.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Shrinks a candidate run from whichever end sits off its best-fit line (by more than
    /// tolerance / 6) — a run found by chord distance leaks into neighbouring arcs, and the leak
    /// shows at its ends — so lines stop at the true tangent points. Interior jitter (JPEG) up to
    /// the tolerance is allowed. Nil if what remains isn't a line (see `minLineLength`, `curves`).
    static func trim(_ run: ClosedRange<Int>, _ pts: [Vec2], tolerance: Double) -> ClosedRange<Int>? {
        var i = run.lowerBound, j = run.upperBound
        while j > i {
            let (c, d) = lineFit(pts, i, j)
            func off(_ k: Int) -> Double { let v = pts[k] - c; return abs(v.x * d.y - v.y * d.x) }
            let oi = off(i), oj = off(j)
            if max(oi, oj) <= tolerance / 6 {
                let length = pts[i].distance(to: pts[j])
                let worst = (i...j).map(off).max()!
                let axisAligned = abs(d.x) < 1e-6 || abs(d.y) < 1e-6
                let isLine = (length >= minLineLength && !curves(pts, i, j, tolerance: tolerance))
                    || (axisAligned && worst <= 0.05 && length >= minExactLineLength)
                return isLine ? i...j : nil
            }
            if oi >= oj { i += 1 } else { j -= 1 }
        }
        return nil
    }

    /// Whether a run with enough samples (≥ 8) shows an arc's curvature: fit residual(t) ≈
    /// α + βt + γt² against the best-fit line, t ∈ [-1, 1]; |γ| approximates the sagitta, which
    /// pixel jitter barely moves. Sparse runs (straight sides sample few points) are not judged.
    static func curves(_ pts: [Vec2], _ i: Int, _ j: Int, tolerance: Double) -> Bool {
        guard j - i + 1 >= 8 else { return false }
        let (c, d) = lineFit(pts, i, j)
        let along = (i...j).map { (pts[$0] - c).dot(d) }
        guard let lo = along.min(), let hi = along.max(), hi > lo else { return false }
        var s = [Double](repeating: 0, count: 5), r = [Double](repeating: 0, count: 3)
        for (k, a) in along.enumerated() {
            let t = 2 * (a - lo) / (hi - lo) - 1
            let v = pts[i + k] - c
            let residual = v.x * d.y - v.y * d.x
            var power = 1.0
            for e in 0..<5 {
                s[e] += power
                if e < 3 { r[e] += residual * power }
                power *= t
            }
        }
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        // Normal equations for (α, β, γ); γ by Cramer's rule.
        let dm = det([[s[0], s[1], s[2]], [s[1], s[2], s[3]], [s[2], s[3], s[4]]])
        guard abs(dm) > 1e-12 else { return false }
        let gamma = det([[s[0], s[1], r[0]], [s[1], s[2], r[1]], [s[2], s[3], r[2]]]) / dm
        return abs(gamma) > tolerance / 5
    }

    /// Least-squares line through pts[i...j]: centroid and unit direction (pointing from i to j).
    static func lineFit(_ pts: [Vec2], _ i: Int, _ j: Int) -> (Vec2, Vec2) {
        let count = Double(j - i + 1)
        let c = pts[i...j].reduce(Vec2.zero, +) * (1 / count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for v in pts[i...j] {
            let d = v - c
            sxx += d.x * d.x; syy += d.y * d.y; sxy += d.x * d.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        var dir = Vec2(cos(angle), sin(angle))
        if dir.dot(pts[j] - pts[i]) < 0 { dir = -dir }
        return (c, dir)
    }

    /// Direction leaving the first point, estimated a few points ahead.
    static func forward(_ pts: [Vec2]) -> Vec2 {
        let k = min(3, pts.count - 1)
        let t = (pts[k] - pts[0]).normalized
        return t == .zero ? (pts[pts.count - 1] - pts[0]).normalized : t
    }

    /// Direction from the last point back into the curve.
    static func backward(_ pts: [Vec2]) -> Vec2 {
        let k = min(3, pts.count - 1)
        let t = (pts[pts.count - 1 - k] - pts[pts.count - 1]).normalized
        return t == .zero ? (pts[0] - pts[pts.count - 1]).normalized : t
    }
}
