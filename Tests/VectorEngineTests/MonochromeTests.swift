import Foundation
import Testing
@testable import VectorEngine

@Suite struct MonochromeTests {
    func run(_ b: Bitmap, _ mono: Monochrome = Monochrome(), _ configure: (inout Options) -> Void = { _ in }) throws -> PipelineState {
        var o = Options()
        o.monochrome = mono
        configure(&o)
        return try Pipeline.run(input: InputImage(bitmap: b), options: o)
    }

    @Test func darkShapesBecomeInkOnTransparent() throws {
        let s = try run(TestImages.circle(size: 48, radius: 16, fg: TestImages.black, bg: TestImages.white, antialias: true))
        let r = try #require(s.result)
        #expect(s.quantized?.palette == [TestImages.black])
        #expect(r.shapes.count == 1 && r.shapes[0].color == TestImages.black)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[24, 24] == TestImages.black && raster[1, 1].a == 0)
    }

    @Test func automaticThresholdSplitsTwoGrays() throws {
        let b = TestImages.circle(size: 48, radius: 16, fg: RGBA(60, 60, 60), bg: RGBA(200, 200, 200), antialias: true)
        #expect(try run(b).result?.shapes.count == 1)
    }

    @Test func explicitThreshold() throws {
        let b = TestImages.circle(size: 48, radius: 16, fg: RGBA(128, 128, 128), bg: TestImages.white)
        #expect(try run(b, Monochrome(threshold: 0.4)).result?.shapes.isEmpty == true)   // 0.5 brightness isn't below 0.4
        #expect(try run(b, Monochrome(threshold: 0.6)).result?.shapes.count == 1)
    }

    @Test func invertTracesLightShapes() throws {
        let b = TestImages.circle(size: 48, radius: 16, fg: TestImages.white, bg: TestImages.black)
        let r = try #require(try run(b, Monochrome(invert: true)).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[24, 24].a == 255 && raster[1, 1].a == 0)
    }

    @Test func inkColorAndBackground() throws {
        let b = TestImages.circle(size: 48, radius: 16, fg: TestImages.black, bg: TestImages.white)
        let r = try #require(try run(b, Monochrome(ink: TestImages.red, background: TestImages.white)).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[24, 24] == TestImages.red && raster[1, 1] == TestImages.white)
    }

    @Test func turnPolicyDecidesDiagonalTouches() throws {
        // Two ink blocks touching only at a corner.
        let b = TestImages.grid(["KKKWWW", "KKKWWW", "KKKWWW", "WWWKKK", "WWWKKK", "WWWKKK"], scale: 4)
        func regions(_ policy: TurnPolicy) throws -> Int {
            var m = Monochrome(); m.turnPolicy = policy
            return try #require(try run(b, m).segmentation).regions.count
        }
        #expect(try regions(.connectInk) == 1)
        #expect(try regions(.separateInk) == 2)
    }

    @Test func borderPadsTheOutput() throws {
        let b = TestImages.circle(size: 40, radius: 18, fg: TestImages.black, bg: TestImages.white)
        let r = try #require(try run(b) { $0.border = 5 }.result)
        #expect(r.width == 50 && r.height == 50)
        let xs = r.shapes.flatMap { $0.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) } }.map(\.x)
        #expect(xs.min()! > 5.5 && xs.max()! < 44.5)   // the disc moved in by the border
    }
}
