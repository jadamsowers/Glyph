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

    static func fitSpan(_ pts: [Vec2], startTangent: Vec2, endTangent: Vec2, params p: CurveParams) -> [PathSegment] {
        let a = pts[0], b = pts[pts.count - 1]
        if pts.count == 2 || pts.dropFirst().dropLast().allSatisfy({ $0.distance(toSegment: a, b) <= p.straightTolerance }) {
            return [.line(to: b)]
        }
        return BezierFit.fit(pts, leftTangent: startTangent, rightTangent: endTangent, tolerance: p.tolerance)
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
