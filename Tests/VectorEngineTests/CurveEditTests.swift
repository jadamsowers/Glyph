import CoreGraphics
import Foundation
import Testing
@testable import VectorEngine

@Suite struct CurveEditTests {
    typealias T = TestImages

    /// Red disk on the left and blue disk on the right, touching a red/blue boundary in the middle
    /// of white: plenty of shared chains and junctions.
    let image = Bitmap(width: 48, height: 32) { x, y in
        let dl = hypot(Double(x) - 15.5, Double(y) - 15.5), dr = hypot(Double(x) - 32.5, Double(y) - 15.5)
        if dl < 11 && x < 24 { return TestImages.red }
        if dr < 11 { return TestImages.blue }
        return TestImages.white
    }

    func points(_ s: [VectorShape]) -> [Vec2] { s.flatMap { $0.subpaths.flatMap { sp in [sp.start] + sp.segments.flatMap(Self.points) } } }
    static func points(_ seg: PathSegment) -> [Vec2] {
        switch seg {
        case .line(let p): [p]
        case .cubic(let a, let b, let p): [a, b, p]
        }
    }

    @Test(arguments: [(false, false, 0), (true, false, 90), (false, true, 180), (true, true, 270), (false, false, 270), (true, false, 0)])
    func outputTransformMatchesTheSVGStage(flipH: Bool, flipV: Bool, rotation: Int) throws {
        for border in [0, 3] {
            for highDetail in [false, true] {
                var o = Options()
                o.flipHorizontal = flipH; o.flipVertical = flipV; o.rotation = rotation; o.border = border
                let input = InputImage(cgImage: image.makeCGImage(), maxDimension: 4000, highDetail: highDetail)
                let s = try Pipeline.run(input: input, options: o)
                let shapes = try #require(s.result?.shapes)
                let preview = try #require(s.previewShapes(s.curves!))
                let t = try #require(s.outputTransform)
                // The preview equals the real output, and mapping the raw shapes through the
                // transform lands on the same points.
                #expect(points(preview) == points(shapes))
                let raw = ShapeAssembler.shapes(topology: s.topology!, regions: s.segmentation!.regions, curves: s.curves!,
                                                tracing: s.resolved!.output.tracing)
                let mapped = points(raw).map { CGPoint(x: $0.x, y: $0.y).applying(t) }
                // The SVG stage may add a background rectangle first; compare the traced points.
                let traced = Array(points(shapes).suffix(mapped.count))
                #expect(zip(mapped, traced).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 },
                        "flip \(flipH),\(flipV) rot \(rotation) border \(border) hd \(highDetail)")
            }
        }
    }

    @Test func committingEditedCurvesRedoesOnlySVG() throws {
        let input = InputImage(bitmap: image)
        let s = try Pipeline.run(input: input, options: Options())
        var curves = try #require(s.curves)
        let c = try #require(curves.indices.first { curves[$0].segments.count >= 2 })
        var editor = CurveEditor(curves: curves)
        let drag = editor.beginDrag(.anchor(chain: c, index: 1))
        editor.update(drag, by: Vec2(2, 1))
        curves = editor.curves
        var reused: [Stage] = []
        let edited = try Pipeline.run(input: input, options: Options(), reusing: s.replacingCurves(curves)) {
            if $0.reused { reused.append($0.stage) }
        }
        #expect(reused == Array(Stage.allCases.dropLast()))
        #expect(edited.curves == curves)
        #expect(edited.result!.svg != s.result!.svg)
    }

    @Test func editingASharedChainMovesBothNeighbors() throws {
        let s = try Pipeline.run(input: InputImage(bitmap: image), options: Options())
        let t = s.topology!, regions = s.segmentation!.regions
        // The chain between the red and the blue disk.
        let c = try #require(t.chains.indices.first { i in
            let colors = Set([t.chains[i].left, t.chains[i].right].filter { $0 >= 0 }.map { regions[Int($0)].color })
            return colors == [T.red, T.blue]
        })
        var editor = CurveEditor(curves: s.curves!)
        let anchors = editor.anchors(of: c)
        let target = CurveEditor.Target.anchor(chain: c, index: anchors.count / 2)
        let before = editor.position(target)
        editor.update(editor.beginDrag(target), by: Vec2(3, 0))
        let moved = before + Vec2(3, 0)
        let shapes = try #require(s.previewShapes(editor.curves))
        for color in [T.red, T.blue] {
            let shape = try #require(shapes.first { $0.color == color })
            #expect(points([shape]).contains(moved), "\(color) shape follows the edit")
        }
    }

    @Test func junctionAnchorsMoveEveryChainThatMeetsThere() {
        // Three open chains meeting at (10, 10).
        let j = Vec2(10, 10)
        let curves = [
            Curve(start: j, segments: [.cubic(c1: Vec2(12, 10), c2: Vec2(18, 10), to: Vec2(20, 10))]),
            Curve(start: Vec2(0, 0), segments: [.cubic(c1: Vec2(2, 2), c2: Vec2(8, 8), to: j)]),
            Curve(start: j, segments: [.line(to: Vec2(10, 20))]),
        ]
        var editor = CurveEditor(curves: curves)
        editor.update(editor.beginDrag(.anchor(chain: 0, index: 0)), by: Vec2(1, -1))
        let k = Vec2(11, 9)
        #expect(editor.curves[0].start == k && editor.curves[1].end == k && editor.curves[2].start == k)
        // Handles travel with their anchor; far ends stay put.
        #expect(editor.curves[0].segments[0] == .cubic(c1: Vec2(13, 9), c2: Vec2(18, 10), to: Vec2(20, 10)))
        #expect(editor.curves[1].segments[0] == .cubic(c1: Vec2(2, 2), c2: Vec2(9, 7), to: k))
        #expect(editor.curves[1].start == Vec2(0, 0))
    }

    @Test func closedCurveStartMovesBothEnds() {
        let curve = Curve(start: Vec2(0, 0), segments: [
            .cubic(c1: Vec2(5, -5), c2: Vec2(15, -5), to: Vec2(20, 0)),
            .cubic(c1: Vec2(15, 5), c2: Vec2(5, 5), to: Vec2(0, 0)),
        ])
        var editor = CurveEditor(curves: [curve])
        #expect(editor.anchors(of: 0).count == 2)   // the closing point is the start, not a third anchor
        editor.update(editor.beginDrag(.anchor(chain: 0, index: 0)), by: Vec2(-2, 0))
        let c = editor.curves[0]
        #expect(c.start == Vec2(-2, 0) && c.end == Vec2(-2, 0))
        #expect(c.segments[0] == .cubic(c1: Vec2(3, -5), c2: Vec2(15, -5), to: Vec2(20, 0)))
        #expect(c.segments[1] == .cubic(c1: Vec2(15, 5), c2: Vec2(3, 5), to: Vec2(-2, 0)))
    }

    @Test func smoothAnchorsKeepTheirHandlesCollinear() {
        // A smooth anchor at (10, 0): incoming handle at (6, 0), outgoing at (14, 0).
        let curve = Curve(start: Vec2(0, 0), segments: [
            .cubic(c1: Vec2(2, 0), c2: Vec2(6, 0), to: Vec2(10, 0)),
            .cubic(c1: Vec2(14, 0), c2: Vec2(18, 0), to: Vec2(20, 0)),
        ])
        var editor = CurveEditor(curves: [curve])
        editor.update(editor.beginDrag(.handle(chain: 0, segment: 1, second: false)), by: Vec2(0, 4))
        // Outgoing handle now at (14, 4); the incoming one rotates opposite, keeping its length 4.
        guard case .cubic(_, let c2, _) = editor.curves[0].segments[0],
              case .cubic(let c1, _, _) = editor.curves[0].segments[1] else { Issue.record("segments changed kind"); return }
        #expect(c1 == Vec2(14, 4))
        let a = Vec2(10, 0), out = (c1 - a).normalized, inc = c2 - a
        #expect(abs(inc.length - 4) < 1e-9 && abs(inc.normalized.dot(out) + 1) < 1e-9)

        // ⌥-drag (breakSmooth) leaves the other handle alone.
        var broken = CurveEditor(curves: [curve])
        broken.update(broken.beginDrag(.handle(chain: 0, segment: 1, second: false), breakSmooth: true), by: Vec2(0, 4))
        #expect(broken.curves[0].segments[0] == curve.segments[0])
    }

    @Test func cornerHandlesMoveIndependently() {
        // A corner at (10, 0): handles at right angles.
        let curve = Curve(start: Vec2(0, 0), segments: [
            .cubic(c1: Vec2(2, 0), c2: Vec2(6, 0), to: Vec2(10, 0)),
            .cubic(c1: Vec2(10, 4), c2: Vec2(10, 8), to: Vec2(10, 10)),
        ])
        var editor = CurveEditor(curves: [curve])
        editor.update(editor.beginDrag(.handle(chain: 0, segment: 1, second: false)), by: Vec2(1, 0))
        #expect(editor.curves[0].segments[0] == curve.segments[0])
    }

    @Test func dragsAreRelativeToTheStartNotCumulative() {
        let curve = Curve(start: Vec2(0, 0), segments: [.cubic(c1: Vec2(3, 0), c2: Vec2(7, 0), to: Vec2(10, 0))])
        var editor = CurveEditor(curves: [curve])
        let drag = editor.beginDrag(.handle(chain: 0, segment: 0, second: true))
        editor.update(drag, by: Vec2(0, 1))
        editor.update(drag, by: Vec2(0, 2))
        #expect(editor.position(.handle(chain: 0, segment: 0, second: true)) == Vec2(7, 2))
    }

    @Test func hitTestingFindsTheNearestChainAndPoint() {
        let curves = [
            Curve(start: Vec2(0, 0), segments: [.cubic(c1: Vec2(3, 0), c2: Vec2(7, 0), to: Vec2(10, 0))]),
            Curve(start: Vec2(0, 10), segments: [.line(to: Vec2(10, 10))]),
        ]
        let editor = CurveEditor(curves: curves)
        // View = 10× the curve coordinates.
        let t = CGAffineTransform(scaleX: 10, y: 10)
        #expect(editor.chain(near: CGPoint(x: 50, y: 3), tolerance: 6, transform: t) == 0)
        #expect(editor.chain(near: CGPoint(x: 50, y: 97), tolerance: 6, transform: t) == 1)
        #expect(editor.chain(near: CGPoint(x: 50, y: 50), tolerance: 6, transform: t) == nil)
        #expect(editor.target(near: CGPoint(x: 71, y: 2), in: 0, tolerance: 6, transform: t) == .handle(chain: 0, segment: 0, second: true))
        #expect(editor.target(near: CGPoint(x: 99, y: 1), in: 0, tolerance: 6, transform: t) == .anchor(chain: 0, index: 1))
    }
}
