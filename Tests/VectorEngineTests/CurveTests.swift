import Foundation
import Testing
@testable import VectorEngine

@Suite struct CurveTests {
    /// Points along a curve, densely sampled, for distance checks.
    func samples(_ start: Vec2, _ segments: [PathSegment]) -> [Vec2] {
        var out = [start], cur = start
        for seg in segments {
            switch seg {
            case .line(let to):
                for i in 1...200 { out.append(cur + (to - cur) * (Double(i) / 200)) }
            case .cubic(let c1, let c2, let to):
                for i in 1...400 { out.append(BezierFit.point([cur, c1, c2, to], Double(i) / 400)) }
            }
            cur = seg.end
        }
        return out
    }

    func shared(_ b: Bitmap, _ options: Options = Options()) throws -> PipelineState {
        try Pipeline.run(input: InputImage(bitmap: b), options: options)
    }

    @Test func quarterCircleFitsWithinTolerance() {
        let pts = (0...30).map { i -> Vec2 in
            let a = Double(i) / 30 * .pi / 2
            return Vec2(20 * cos(a), 20 * sin(a))
        }
        let segs = BezierFit.fit(pts, leftTangent: Vec2(0, 1), rightTangent: Vec2(1, 0), tolerance: 0.25)
        #expect(segs.count <= 2)
        let curve = samples(pts[0], segs)
        for p in pts { #expect(curve.map { $0.distance(to: p) }.min()! < 0.3) }
        #expect(segs.last?.end == pts.last)
    }

    @Test func squareBecomesFourLines() {
        let b = Bitmap(width: 20, height: 20) { x, y in
            (5..<15).contains(x) && (5..<15).contains(y) ? TestImages.red : TestImages.white
        }
        let seg = Segmenter.segment(Quantizer.assign(b, palette: [TestImages.red, TestImages.white], alphaThreshold: 128), params: SegmentParams(speckSize: 0))
        let t = Topology.build(seg)
        let r = seg.label(10, 10)
        let chain = t.chains.first { $0.left == r || $0.right == r }!
        let poly = PolygonBuilder.build(chain, params: PolygonParams(tolerance: 1, cornerAngle: 60, cornerRunLength: 2, straightTolerance: 0.6))
        let curve = CurveFitter.fit(poly, params: CurveParams(tolerance: 1, straightTolerance: 0.6))
        #expect(curve.segments.count == 4)
        #expect(curve.segments.allSatisfy { if case .line = $0 { true } else { false } })
        #expect(curve.end == curve.start)
    }

    @Test func circleBecomesAFewCubicsAndStaysFaithful() throws {
        let s = try shared(TestImages.circle(size: 48, radius: 16, antialias: true))
        let result = try #require(s.result)
        #expect(result.shapes.count == 2)
        let disc = try #require(result.shapes.first { Lab($0.color).distance(to: Lab(TestImages.red)) < 5 })
        #expect(disc.subpaths.count == 1 && disc.subpaths[0].segments.count <= 8)
        let raster = ShapeRenderer.rasterize(result.shapes, width: 48, height: 48, antialias: false, background: TestImages.magenta)
        #expect(!raster.pixels.contains(TestImages.magenta))
        #expect(TestImages.agreement(raster, try #require(s.quantized).makeBitmap()) > 0.97)
    }

    // Review focus: thin ring around a larger disk, stacked mode.
    @Test func stackedModeKeepsRingAndDiskVisible() throws {
        let b = TestImages.ringAroundDisk()
        let r = try #require(try shared(b, Options(tracing: .stacked)).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 40, height: 40, antialias: false)
        #expect(raster[20, 20] == TestImages.blue)
        #expect(raster[20, 6] == TestImages.red)
        #expect(TestImages.agreement(raster, b) > 0.95)
    }

    @Test(arguments: TracingMode.allCases)
    func busyImageStaysCoveredAndFaithful(tracing: TracingMode) throws {
        let b = TestImages.randomBlocks(width: 32, height: 32)
        let s = try shared(b, Options(tracing: tracing, speckSize: 0))
        let raster = ShapeRenderer.rasterize(try #require(s.result).shapes, width: 32, height: 32, antialias: false, background: TestImages.magenta)
        #expect(raster.pixels.filter { $0 == TestImages.magenta }.isEmpty)
        #expect(TestImages.agreement(raster, try #require(s.quantized).makeBitmap()) > 0.85)
    }

    @Test func curvesShrinkTheSVG() throws {
        // Same image traced with tight vs loose detail: loose must not be larger.
        let b = TestImages.circle(size: 64, radius: 24, antialias: true)
        let tight = try #require(try shared(b, Options(detail: 1)).result)
        let loose = try #require(try shared(b, Options(detail: 0)).result)
        #expect(loose.stats.byteCount <= tight.stats.byteCount)
    }
}
