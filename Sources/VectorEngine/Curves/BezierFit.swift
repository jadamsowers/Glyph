/// Least-squares cubic Bézier fitting (Schneider, "An Algorithm for Automatically Fitting
/// Digitized Curves", Graphics Gems, 1990).
enum BezierFit {
    /// Fits cubics through `pts` (≥ 2 points), starting at pts[0]. `leftTangent` points from the
    /// start into the curve; `rightTangent` points from the end back into the curve (unit vectors).
    static func fit(_ pts: [Vec2], leftTangent: Vec2, rightTangent: Vec2, tolerance: Double) -> [PathSegment] {
        var out: [PathSegment] = []
        fitCubic(pts, 0, pts.count - 1, leftTangent, rightTangent, tolerance * tolerance, &out)
        return out
    }

    /// The single least-squares cubic through `pts` (≥ 2) with the given end tangents, refined by a
    /// few Newton–Raphson reparameterizations (no splitting).
    static func single(_ pts: [Vec2], leftTangent: Vec2, rightTangent: Vec2) -> PathSegment {
        let last = pts.count - 1
        guard last >= 2 else {
            let dist = pts[0].distance(to: pts[last]) / 3
            return .cubic(c1: pts[0] + leftTangent * dist, c2: pts[last] + rightTangent * dist, to: pts[last])
        }
        var u = chordLengthParameterize(pts, 0, last)
        var bez = generateBezier(pts, 0, last, u, leftTangent, rightTangent)
        for _ in 0..<4 {
            u = reparameterize(pts, 0, u, bez)
            bez = generateBezier(pts, 0, last, u, leftTangent, rightTangent)
        }
        return .cubic(c1: bez[1], c2: bez[2], to: bez[3])
    }

    /// `error` is a squared distance.
    private static func fitCubic(_ d: [Vec2], _ first: Int, _ last: Int, _ t1: Vec2, _ t2: Vec2, _ error: Double, _ out: inout [PathSegment]) {
        if last - first == 1 {
            let dist = d[first].distance(to: d[last]) / 3
            out.append(.cubic(c1: d[first] + t1 * dist, c2: d[last] + t2 * dist, to: d[last]))
            return
        }
        var u = chordLengthParameterize(d, first, last)
        var bez = generateBezier(d, first, last, u, t1, t2)
        var (maxError, split) = computeMaxError(d, first, last, bez, u)
        if maxError < error { out.append(.cubic(c1: bez[1], c2: bez[2], to: bez[3])); return }
        if maxError < error * 4 {
            for _ in 0..<4 {
                u = reparameterize(d, first, u, bez)
                bez = generateBezier(d, first, last, u, t1, t2)
                (maxError, split) = computeMaxError(d, first, last, bez, u)
                if maxError < error { out.append(.cubic(c1: bez[1], c2: bez[2], to: bez[3])); return }
            }
        }
        var center = (d[split - 1] - d[split + 1]).normalized
        if center == .zero { center = (d[split - 1] - d[split]).normalized }
        fitCubic(d, first, split, t1, center, error, &out)
        fitCubic(d, split, last, -center, t2, error, &out)
    }

    private static func chordLengthParameterize(_ d: [Vec2], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last { u.append(u[u.count - 1] + d[i].distance(to: d[i - 1])) }
        let total = u[u.count - 1]
        return total > 0 ? u.map { $0 / total } : u.indices.map { Double($0) / Double(u.count - 1) }
    }

    private static func generateBezier(_ d: [Vec2], _ first: Int, _ last: Int, _ u: [Double], _ t1: Vec2, _ t2: Vec2) -> [Vec2] {
        let p0 = d[first], p3 = d[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for (i, t) in u.enumerated() {
            let a0 = t1 * b1(t), a1 = t2 * b2(t)
            c00 += a0.dot(a0)
            c01 += a0.dot(a1)
            c11 += a1.dot(a1)
            let tmp = d[first + i] - (p0 * (b0(t) + b1(t)) + p3 * (b2(t) + b3(t)))
            x0 += a0.dot(tmp)
            x1 += a1.dot(tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alphaL = det == 0 ? 0 : (x0 * c11 - x1 * c01) / det
        var alphaR = det == 0 ? 0 : (c00 * x1 - c01 * x0) / det
        let segLength = p0.distance(to: p3)
        let epsilon = 1e-6 * segLength
        // A near-singular system (few, nearly collinear points) can give enormous handles that
        // still pass through every sample yet loop far outside them. Reject handles that overshoot
        // each other along the chord, or reach well beyond the points themselves.
        let spread = (first...last).reduce(0.0) { max($0, d[$1].distance(to: p0), d[$1].distance(to: p3)) }
        let chord = p3 - p0
        let overshoot = (t1 * alphaL).dot(chord) - (t2 * alphaR).dot(chord) > segLength * segLength
        if alphaL < epsilon || alphaR < epsilon || overshoot || max(alphaL, alphaR) > 2.5 * spread {
            alphaL = (segLength > 0 ? segLength : spread) / 3
            alphaR = alphaL
        }
        return [p0, p0 + t1 * alphaL, p3 + t2 * alphaR, p3]
    }

    /// Largest squared distance between a point and its parameter's position on the curve.
    private static func computeMaxError(_ d: [Vec2], _ first: Int, _ last: Int, _ bez: [Vec2], _ u: [Double]) -> (Double, Int) {
        var maxDist = 0.0, split = (last - first + 1) / 2 + first
        for i in (first + 1)..<last {
            let v = point(bez, u[i - first]) - d[i]
            let dist = v.dot(v)
            if dist >= maxDist { maxDist = dist; split = i }
        }
        return (maxDist, split)
    }

    private static func reparameterize(_ d: [Vec2], _ first: Int, _ u: [Double], _ bez: [Vec2]) -> [Double] {
        u.enumerated().map { newtonRaphson(bez, d[first + $0.offset], $0.element) }
    }

    private static func newtonRaphson(_ q: [Vec2], _ p: Vec2, _ u: Double) -> Double {
        let q1 = [(q[1] - q[0]) * 3, (q[2] - q[1]) * 3, (q[3] - q[2]) * 3]
        let q2 = [(q1[1] - q1[0]) * 2, (q1[2] - q1[1]) * 2]
        let qu = point(q, u)
        let q1u = q1[0] * ((1 - u) * (1 - u)) + q1[1] * (2 * u * (1 - u)) + q1[2] * (u * u)
        let q2u = q2[0] * (1 - u) + q2[1] * u
        let num = (qu - p).dot(q1u)
        let den = q1u.dot(q1u) + (qu - p).dot(q2u)
        guard den != 0 else { return u }
        return max(0, min(1, u - num / den))
    }

    static func point(_ b: [Vec2], _ t: Double) -> Vec2 {
        b[0] * b0(t) + b[1] * b1(t) + b[2] * b2(t) + b[3] * b3(t)
    }

    private static func b0(_ t: Double) -> Double { let m = 1 - t; return m * m * m }
    private static func b1(_ t: Double) -> Double { let m = 1 - t; return 3 * t * m * m }
    private static func b2(_ t: Double) -> Double { 3 * t * t * (1 - t) }
    private static func b3(_ t: Double) -> Double { t * t * t }
}
