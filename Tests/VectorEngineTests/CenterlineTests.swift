import Foundation
import Testing
@testable import VectorEngine

@Suite struct CenterlineTests {
    func trace(_ b: Bitmap) throws -> VectorResult {
        var o = Options(); o.centerline = true
        return try #require(try Pipeline.run(input: InputImage(bitmap: b), options: o).result)
    }
    func points(_ r: VectorResult) -> [Vec2] { r.shapes.flatMap { $0.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) } } }

    @Test func barBecomesOneStrokedLine() throws {
        let bar = Bitmap(width: 80, height: 48) { x, y in (10..<70).contains(x) && (20..<28).contains(y) ? TestImages.black : TestImages.white }
        let r = try trace(bar)
        #expect(r.shapes.count == 1)
        let shape = try #require(r.shapes.first)
        #expect(shape.subpaths.count == 1 && !shape.subpaths[0].isClosed)
        #expect(abs(try #require(shape.stroke) - 8) < 1.5)
        for p in points(r) { #expect(abs(p.y - 24) < 1, "\(p)") }
        let xs = points(r).map(\.x)
        #expect(xs.min()! < 16 && xs.max()! > 64)
        #expect(r.svg.contains("fill=\"none\"") && r.svg.contains("stroke-width"))
        #expect(XMLParser(data: Data(r.svg.utf8)).parse())
    }

    @Test func ringBecomesOneClosedLoop() throws {
        let ring = Bitmap(width: 60, height: 60) { x, y in
            let d = ((Double(x) + 0.5 - 30) * (Double(x) + 0.5 - 30) + (Double(y) + 0.5 - 30) * (Double(y) + 0.5 - 30)).squareRoot()
            return d >= 15 && d <= 19 ? TestImages.black : TestImages.white
        }
        let r = try trace(ring)
        let subpaths = r.shapes.flatMap(\.subpaths)
        #expect(subpaths.count == 1 && subpaths[0].isClosed)
        for p in points(r) { #expect(abs(p.distance(to: Vec2(30, 30)) - 17) < 1.5, "\(p)") }
        #expect(abs(try #require(r.shapes.first?.stroke) - 4) < 1.5)
    }

    @Test func teeHasThreeArmsAndNoSpurs() throws {
        let tee = Bitmap(width: 80, height: 80) { x, y in
            ((10..<70).contains(x) && (10..<18).contains(y)) || ((36..<44).contains(x) && (10..<70).contains(y)) ? TestImages.black : TestImages.white
        }
        let n = try trace(tee).shapes.flatMap(\.subpaths).count
        #expect(n >= 2 && n <= 3, "\(n) paths")
    }

    @Test func strokesCoverTheInk() throws {
        let bar = Bitmap(width: 80, height: 48) { x, y in (10..<70).contains(x) && (20..<28).contains(y) ? TestImages.black : TestImages.white }
        let r = try trace(bar)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 80, height: 48, antialias: false)
        var inked = 0, covered = 0
        for i in bar.pixels.indices where bar.pixels[i] == TestImages.black { inked += 1; if raster.pixels[i].a > 0 { covered += 1 } }
        #expect(Double(covered) / Double(inked) > 0.85)
    }
}
