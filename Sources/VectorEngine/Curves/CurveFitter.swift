enum CurveFitter {
    // Walking-skeleton version: straight lines through the polygon. Task 10 replaces this file.
    static func fit(_ polys: [PolyChain], params: CurveParams) -> [Curve] {
        polys.map { p in
            var pts = p.polygon
            if p.isClosed { pts.append(pts[0]) }
            return Curve.polyline(pts)
        }
    }
}
