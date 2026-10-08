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
                out += BezierFit.fit(Array(pts[cursor...run.lowerBound]), leftTangent: cursorTangent,
                                     rightTangent: -direction, tolerance: p.tolerance)
            }
            out.append(.line(to: pts[run.upperBound]))
            cursor = run.upperBound
            cursorTangent = direction
        }
        if cursor < pts.count - 1 {
            out += BezierFit.fit(Array(pts[cursor...]), leftTangent: cursorTangent, rightTangent: endTangent, tolerance: p.tolerance)
        }
        return out
    }

    /// Runs shorter than this (px) are left to the curve fitter.
    static let minLineLength = 12.0

    /// Stretches of points that lie on a line: every point within `tolerance` of the chord, at
    /// least `minLineLength` long, and not bulging (see `bulges`). Longest runs are taken first so
    /// a run can't start inside an arc and cut across a side. Ascending, sharing at most endpoints.
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
            if pts[i].distance(to: pts[j]) >= minLineLength { candidates.append(i...j) }
        }
        var accepted: [ClosedRange<Int>] = []
        for c in candidates.sorted(by: { pts[$0.lowerBound].distance(to: pts[$0.upperBound]) > pts[$1.lowerBound].distance(to: pts[$1.upperBound]) }) {
            guard accepted.allSatisfy({ c.lowerBound >= $0.upperBound || c.upperBound <= $0.lowerBound }),
                  !bulges(pts, c.lowerBound, c.upperBound, tolerance: tolerance)
            else { continue }
            accepted.append(c)
        }
        return accepted.sorted { $0.lowerBound < $1.lowerBound }
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

    /// An arc's middle sits consistently to one side of its best-fit line; a straight (even
    /// jittery) edge's doesn't. True if the middle half's mean residual exceeds tolerance / 6.
    static func bulges(_ pts: [Vec2], _ i: Int, _ j: Int, tolerance: Double) -> Bool {
        let (c, d) = lineFit(pts, i, j)
        let lo = i + (j - i) / 4, hi = j - (j - i) / 4
        guard hi > lo else { return false }
        let mean = (lo...hi).reduce(0.0) { sum, k in
            let r = pts[k] - c
            return sum + (r.x * d.y - r.y * d.x)
        } / Double(hi - lo + 1)
        return abs(mean) > tolerance / 6
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
