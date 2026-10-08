import Testing
@testable import VectorEngine

@Suite struct PolygonTests {
    let params = PolygonParams(tolerance: 1.0, cornerAngle: 60, cornerRunLength: 2, straightTolerance: 0.6)

    func trace(_ b: Bitmap, palette: [RGBA]) -> (Segmentation, Topology) {
        let seg = Segmenter.segment(Quantizer.assign(b, palette: palette, alphaThreshold: 128), params: SegmentParams(speckSize: 0))
        return (seg, Topology.build(seg))
    }

    /// The polygon of the (single, closed) chain around the region containing pixel (x, y).
    func polygon(around x: Int, _ y: Int, in b: Bitmap, palette: [RGBA]) -> PolyChain {
        let (seg, t) = trace(b, palette: palette)
        let r = seg.label(x, y)
        let chain = t.chains.first { $0.left == r || $0.right == r }!
        return PolygonBuilder.build(chain, params: params)
    }

    @Test func axisAlignedSquareBecomesFourCorners() {
        let b = Bitmap(width: 20, height: 20) { x, y in
            (5..<15).contains(x) && (5..<15).contains(y) ? TestImages.red : TestImages.white
        }
        let poly = polygon(around: 10, 10, in: b, palette: [TestImages.red, TestImages.white])
        #expect(Set(poly.polygon) == [Vec2(5, 5), Vec2(15, 5), Vec2(15, 15), Vec2(5, 15)])
        #expect(poly.corners == [true, true, true, true])
    }

    @Test func diamondKeepsFourCorners() {
        let b = Bitmap(width: 25, height: 25) { x, y in abs(x - 12) + abs(y - 12) <= 9 ? TestImages.red : TestImages.white }
        let poly = polygon(around: 12, 12, in: b, palette: [TestImages.red, TestImages.white])
        #expect(poly.corners.filter { $0 }.count == 4)
        #expect(poly.vertices.count <= 8)
    }

    @Test func antialiasedTriangleKeepsThreeSharpCorners() {
        let corners = [Vec2(32, 6), Vec2(58, 56), Vec2(6, 56)]
        func inside(_ p: Vec2) -> Bool {
            (0..<3).allSatisfy { i in
                let a = corners[i], b = corners[(i + 1) % 3]
                return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0
            }
        }
        let b = Bitmap(width: 64, height: 64) { x, y in
            var n = 0
            for sy in 0..<4 { for sx in 0..<4 where inside(Vec2(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4)) { n += 1 } }
            return TestImages.blend(TestImages.red, TestImages.white, Double(n) / 16)
        }
        let q = Quantizer.logo(b, params: QuantizeParams(kind: .logo, colorCount: 8))
        let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 4))
        let r = seg.label(32, 40)
        let chain = Topology.build(seg).chains.first { $0.left == r || $0.right == r }!
        let poly = PolygonBuilder.build(chain, params: params)
        #expect(poly.vertices.count == 3)
        #expect(poly.corners == [true, true, true])
        for v in poly.polygon { #expect(corners.map { $0.distance(to: v) }.min()! < 1.5) }
    }

    // Regression: small rounded corners must not be "sharpened" into square corners.
    @Test(arguments: [4.0, 6.0, 9.0])
    func smallRoundedCornersStayRounded(radius: Double) {
        let b = TestImages.roundedRect(width: 160, height: 100, inset: 20, radius: radius)
        let q = Quantizer.logo(b, params: QuantizeParams(kind: .logo, colorCount: 8))
        let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 4))
        let r = seg.label(80, 50)
        let poly = PolygonBuilder.build(Topology.build(seg).chains.first { $0.left == r || $0.right == r }!, params: params)
        for v in poly.polygon {
            #expect(TestImages.roundedRectDistance(v, width: 160, height: 100, inset: 20, radius: radius) < 1.0, "\(v)")
        }
    }

    @Test func circleHasNoCorners() {
        let poly = polygon(around: 20, 20, in: TestImages.circle(size: 40, radius: 12), palette: [TestImages.red, TestImages.white])
        #expect(poly.corners.allSatisfy { !$0 })
        #expect(poly.vertices.count <= 20)
    }

    @Test func singlePixelKeepsAShape() {
        let b = TestImages.grid(["WWW", "WRW", "WWW"])
        let poly = polygon(around: 1, 1, in: b, palette: [TestImages.red, TestImages.white])
        #expect(poly.vertices.count >= 3)
    }

    @Test func shallowStaircaseIsOneStraightEdge() {
        let b = Bitmap(width: 30, height: 12) { x, y in y * 3 >= x ? TestImages.red : TestImages.white }
        let (seg, t) = trace(b, palette: [TestImages.red, TestImages.white])
        let pair = Set([seg.label(0, 11), seg.label(29, 0)])
        let chain = t.chains.first { Set([$0.left, $0.right]) == pair }!
        #expect(PolygonBuilder.build(chain, params: params).vertices.count == 2)
    }

    @Test func openChainsKeepTheirJunctionEndpoints() {
        let b = Bitmap(width: 30, height: 10) { x, _ in x < 10 ? TestImages.red : (x < 20 ? TestImages.white : TestImages.blue) }
        let (_, t) = trace(b, palette: [TestImages.red, TestImages.white, TestImages.blue])
        let open = t.chains.filter { !$0.isClosed }
        #expect(!open.isEmpty)
        for chain in open {
            let poly = PolygonBuilder.build(chain, params: params)
            #expect(poly.dense.first == chain.points.first!.vec && poly.dense.last == chain.points.last!.vec)
            #expect(poly.vertices.first == 0 && poly.vertices.last == poly.dense.count - 1)
            #expect(poly.corners.first == true && poly.corners.last == true)
        }
    }
}
