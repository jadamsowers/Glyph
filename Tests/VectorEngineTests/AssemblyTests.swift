import Foundation
import Testing
@testable import VectorEngine

@Suite struct AssemblyTests {
    /// Exact palette → regions → chains, outlined with straight pixel-edge polylines.
    func polylineResult(_ b: Bitmap, palette: [RGBA], tracing: TracingMode) -> (QuantizedImage, VectorResult) {
        let q = Quantizer.assign(b, palette: palette, alphaThreshold: 128)
        let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 0))
        let t = Topology.build(seg)
        let curves = t.chains.map { Curve.polyline($0.points.map(\.vec)) }
        let shapes = ShapeAssembler.shapes(topology: t, regions: seg.regions, curves: curves, tracing: tracing)
        return (q, VectorResult(shapes: shapes, width: b.width, height: b.height, precision: 1))
    }

    @Test(arguments: TracingMode.allCases)
    func polylinesReproduceThePixelsExactly(tracing: TracingMode) {
        let b = TestImages.randomBlocks()
        let (q, r) = polylineResult(b, palette: [TestImages.red, TestImages.blue, TestImages.white], tracing: tracing)
        let raster = ShapeRenderer.rasterize(r.shapes, width: b.width, height: b.height, antialias: false)
        #expect(TestImages.agreement(raster, q.makeBitmap()) == 1)
    }

    // Review focus: transparent-background logo.
    @Test func transparentBackgroundEmitsNoBackgroundPath() {
        let (_, r) = polylineResult(TestImages.circle(bg: .clear), palette: [TestImages.red], tracing: .sharedEdges)
        #expect(r.shapes.count == 1)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[0, 0].a == 0 && raster[24, 24] == TestImages.red)
    }

    @Test func sharedModeMergesSameColoredRegionsStackedDoesNot() {
        let b = TestImages.grid(["RWR"])
        #expect(polylineResult(b, palette: [TestImages.red, TestImages.white], tracing: .sharedEdges).1.shapes.count == 2)
        #expect(polylineResult(b, palette: [TestImages.red, TestImages.white], tracing: .stacked).1.shapes.count == 3)
    }

    @Test func svgIsWellFormed() {
        let (_, r) = polylineResult(TestImages.randomBlocks(), palette: [TestImages.red, TestImages.blue, TestImages.white], tracing: .sharedEdges)
        #expect(XMLParser(data: Data(r.svg.utf8)).parse())
        #expect(r.svg.contains("viewBox=\"0 0 24 24\""))
        #expect(r.svg.components(separatedBy: "<path ").count - 1 == r.shapes.count)
        #expect(r.stats.byteCount == r.svg.utf8.count && r.stats.pathCount == r.shapes.count)
    }

    @Test func numberFormatting() {
        #expect(SVGWriter.format(5, precision: 1) == ".5")
        #expect(SVGWriter.format(-5, precision: 1) == "-.5")
        #expect(SVGWriter.format(120, precision: 1) == "12")
        #expect(SVGWriter.format(-1234, precision: 2) == "-12.34")
        #expect(SVGWriter.format(0, precision: 1) == "0")
        #expect(SVGWriter.format(7, precision: 0) == "7")
    }

    @Test func pathDataIsRelativeAndCompact() {
        let square = Subpath(start: Vec2(0, 0), segments: [
            .line(to: Vec2(10, 0)), .line(to: Vec2(10, 10)), .line(to: Vec2(0, 10)), .line(to: Vec2(0, 0)),
        ])
        #expect(SVGWriter.pathData([square], precision: 1) == "M0 0l10 0 0 10-10 0z")
        let curve = Subpath(start: Vec2(1, 1), segments: [
            .cubic(c1: Vec2(2, 1), c2: Vec2(3, 2), to: Vec2(3, 3)), .line(to: Vec2(1, 1)),
        ])
        #expect(SVGWriter.pathData([curve], precision: 1) == "M1 1c1 0 2 1 2 2z")
    }

    @Test func reversedCurveRoundTrips() {
        let c = Curve(start: Vec2(0, 0), segments: [.line(to: Vec2(1, 0)), .cubic(c1: Vec2(2, 0), c2: Vec2(3, 1), to: Vec2(3, 2))])
        let r = c.reversed()
        #expect(r.start == Vec2(3, 2) && r.end == Vec2(0, 0))
        #expect(r.segments.first == .cubic(c1: Vec2(3, 1), c2: Vec2(2, 0), to: Vec2(1, 0)))
        #expect(r.reversed() == c)
    }

    @Test func degenerateImages() {
        let (_, empty) = polylineResult(Bitmap(width: 4, height: 4) { _, _ in .clear }, palette: [], tracing: .sharedEdges)
        #expect(empty.shapes.isEmpty)
        #expect(XMLParser(data: Data(empty.svg.utf8)).parse())
        let (_, dot) = polylineResult(Bitmap(width: 1, height: 1) { _, _ in TestImages.red }, palette: [TestImages.red], tracing: .stacked)
        #expect(dot.shapes.count == 1)
    }
}
