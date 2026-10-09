import Foundation
import Testing
@testable import VectorEngine

@Suite struct AdjustTests {
    func one(_ c: RGBA, _ a: Adjustments) -> RGBA { Prefilter.adjust(Bitmap(width: 1, height: 1) { _, _ in c }, a)[0, 0] }

    @Test func identityChangesNothing() {
        #expect(one(RGBA(12, 130, 240, 200), Adjustments()) == RGBA(12, 130, 240, 200))
    }

    @Test func brightnessContrastGammaInvert() {
        #expect(one(RGBA(100, 100, 100), Adjustments(brightness: 0.2)).r > 140)
        #expect(one(RGBA(100, 100, 100), Adjustments(contrast: 2)).r < 80)          // below mid-gray gets darker
        #expect(one(RGBA(64, 64, 64), Adjustments(gamma: 2)).r > 100)               // gamma > 1 brightens midtones
        #expect(one(RGBA(10, 200, 30, 90), Adjustments(invert: true)) == RGBA(245, 55, 225, 90))
    }

    @Test func saturationSeparatesMutedColors() {
        let gray = one(RGBA(150, 100, 100), Adjustments(saturation: 0))
        #expect(gray.r == gray.g && gray.g == gray.b)
        let vivid = one(RGBA(150, 100, 100), Adjustments(saturation: 2))
        #expect(Int(vivid.r) - Int(vivid.g) > 50)
    }

    @Test func medianRemovesIsolatedNoise() {
        var b = Bitmap(width: 9, height: 9) { _, _ in TestImages.white }
        b[4, 4] = TestImages.black
        #expect(Prefilter.median(b, radius: 1)[4, 4] == TestImages.white)
        // …but keeps an edge.
        let edge = Bitmap(width: 9, height: 9) { x, _ in x < 4 ? TestImages.black : TestImages.white }
        #expect(Prefilter.median(edge, radius: 1)[2, 4] == TestImages.black && Prefilter.median(edge, radius: 1)[6, 4] == TestImages.white)
    }

    @Test func adjustmentsReachTheTracer() throws {
        // Inverting a black disc on white in black-and-white mode inks the background instead.
        var o = Options()
        o.monochrome = Monochrome()
        o.adjust = Adjustments(invert: true)
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: TestImages.circle(fg: TestImages.black, bg: TestImages.white)), options: o).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[1, 1].a == 255 && raster[24, 24].a == 0)
    }
}
