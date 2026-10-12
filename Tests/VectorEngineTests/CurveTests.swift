import CoreGraphics
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

    // Regression: the straight sides of a rounded rectangle must come out as straight lines,
    // with the corners as curves hugging the true outline.
    @Test(arguments: [6.0, 10.0, 12.0, 24.0])
    func roundedRectangleKeepsStraightSides(radius: Double) throws {
        let b = TestImages.roundedRect(width: 160, height: 100, inset: 20, radius: radius)
        let s = try shared(b)
        let seg = try #require(s.segmentation), lbl = seg.label(80, 50)
        let i = try #require(s.topology?.chains.firstIndex { $0.left == lbl || $0.right == lbl })
        let curve = try #require(s.curves)[i]
        // Each side's straight part: 120 − 2r horizontally, 60 − 2r vertically.
        let lines = curve.segments.enumerated().compactMap { k, seg -> (Vec2, Vec2)? in
            guard case .line(let to) = seg else { return nil }
            return (k == 0 ? curve.start : curve.segments[k - 1].end, to)
        }
        let horizontal = lines.filter { abs($0.0.y - $0.1.y) < 0.5 && abs($0.0.x - $0.1.x) >= 0.8 * (120 - 2 * radius) }
        let vertical = lines.filter { abs($0.0.x - $0.1.x) < 0.5 && abs($0.0.y - $0.1.y) >= 0.8 * (60 - 2 * radius) }
        #expect(horizontal.count == 2 && vertical.count == 2, "lines: \(lines)")
        for p in samples(curve.start, curve.segments) {
            #expect(TestImages.roundedRectDistance(p, width: 160, height: 100, inset: 20, radius: radius) < 1.0, "\(p)")
        }
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

@Suite struct SmallIconTests {
    /// Tangent turn (degrees) where consecutive segments of a closed subpath meet.
    func kinks(_ sp: Subpath) -> [Double] {
        var out: [Double] = []
        var cur = sp.start
        var tangents: [(Vec2, Vec2)] = []   // (start tangent, end tangent) per segment
        for seg in sp.segments {
            switch seg {
            case .line(let to): let d = (to - cur).normalized; tangents.append((d, d))
            case .cubic(let c1, let c2, let to):
                let a = (c1 - cur).length > 1e-6 ? (c1 - cur).normalized : (to - cur).normalized
                let b = (to - c2).length > 1e-6 ? (to - c2).normalized : (to - cur).normalized
                tangents.append((a, b))
            }
            cur = seg.end
        }
        for k in tangents.indices {
            let end = tangents[k].1, next = tangents[(k + 1) % tangents.count].0
            out.append(acos(max(-1, min(1, end.dot(next)))) * 180 / .pi)
        }
        return out
    }

    // Regression: small outlined rounded rects (the outline breaks into several gray regions,
    // creating junctions at corners) must trace without kinks or chamfered corners.
    @Test func outlinedRoundedRectsAreSmoothAndFaithful() throws {
        let icon = TestImages.outlinedIcon()
        let input = InputImage(cgImage: icon.makeCGImage(), maxDimension: 2000, minDimension: 256)
        let s = try Pipeline.run(input: input, options: Options(kind: .logo))
        let seg = try #require(s.segmentation), topo = try #require(s.topology), curves = try #require(s.curves)
        for (rect, _) in TestImages.iconRects {
            let fill = rect.insetBy(dx: 0.5, dy: 0.5)
            let f = Double(input.upscale)
            let label = Int(seg.label(Int(rect.midX * f), Int(rect.midY * f)))
            let loop = topo.regions[label].loops[topo.regions[label].outerIndex]
            let outline = VectorShape(color: .clear, subpaths: [ShapeAssembler.subpath(loop, curves)])
                .scaled(input.scaleX, input.scaleY).subpaths[0]
            let turns = kinks(outline)
            #expect(turns.max()! < 25, "rect \(rect): kinks \(turns.filter { $0 >= 25 }.map { Int($0) })")
            var cur = outline.start
            for sg in outline.segments {
                let pts: [Vec2] = switch sg {
                case .line(let to): (0...10).map { cur + (to - cur) * (Double($0) / 10) }
                case .cubic(let c1, let c2, let to): (0...20).map { BezierFit.point([cur, c1, c2, to], Double($0) / 20) }
                }
                for p in pts { #expect(TestImages.roundedRectDistance(p, rect: fill, radius: 5.5) < 0.8, "rect \(rect): \(p)") }
                cur = sg.end
            }
        }
    }
}

extension SmallIconTests {
    // Regression (user report): a small arrow glyph's tips must stay sharp, not get rounded off.
    @Test func smallArrowKeepsSharpTips() throws {
        // A thick arrow pointing up-right, as a polygon, drawn anti-aliased at 62 px.
        let arrow = [Vec2(20, 38), Vec2(33, 25), Vec2(27, 25), Vec2(27, 20), Vec2(42, 20), Vec2(42, 35),
                     Vec2(37, 35), Vec2(37, 29), Vec2(24, 42)]
        let icon = Bitmap.render(width: 62, height: 62) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.76, blue: 0.53, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 62, height: 62))
            ctx.addLines(between: arrow.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.closePath()
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
        }
        let input = InputImage(cgImage: icon.makeCGImage(), maxDimension: 2000, minDimension: 256)
        let r = try #require(try Pipeline.run(input: input, options: Options(kind: .logo)).result)
        let white = try #require(r.shapes.first { $0.color.r > 240 && $0.color.g > 240 })
        let anchors = white.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) }
        // The arrowhead's outer tip and the tail's end corners must each have an anchor nearby.
        for tip in [Vec2(42, 20), Vec2(20, 38), Vec2(24, 42)] {
            #expect(anchors.map { $0.distance(to: tip) }.min()! < 1.0, "no anchor near \(tip)")
        }
    }
}

@Suite struct BezierHandleTests {
    /// Short point runs with arbitrary end tangents (as tiny boundary pieces produce) must never
    /// get handles that fly far outside the points: such a cubic still passes through the samples
    /// but draws a long hairline loop across the image.
    @Test func handlesStayNearThePoints() {
        var rng = SplitMix64(seed: 11)
        func r(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &rng) }
        var worst = 0.0
        for _ in 0..<5000 {
            let n = Int.random(in: 3...6, using: &rng)
            let pts = (0..<n).map { _ in Vec2(r(0...4), r(0...4)) }
            let a = r(0...(2 * .pi)), b = r(0...(2 * .pi))
            let t1 = Vec2(cos(a), sin(a)), t2 = Vec2(cos(b), sin(b))
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let size = max(1, hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!))
            var segs = BezierFit.fit(pts, leftTangent: t1, rightTangent: t2, tolerance: 0.5)
            segs.append(BezierFit.single(pts, leftTangent: t1, rightTangent: t2))
            for case .cubic(let c1, let c2, _) in segs {
                for c in [c1, c2] {
                    let d = pts.map { hypot($0.x - c.x, $0.y - c.y) }.min()!
                    worst = max(worst, d / size)
                }
            }
        }
        #expect(worst < 3, "a control point reached \(worst)× the point spread away")
    }
}
