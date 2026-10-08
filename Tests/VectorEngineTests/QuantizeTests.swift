import Testing
@testable import VectorEngine

@Suite struct QuantizeTests {
    func logo(_ b: Bitmap, colors: Int = 8) -> QuantizedImage {
        Quantizer.logo(b, params: QuantizeParams(kind: .logo, colorCount: colors))
    }

    @Test func antialiasedTwoColorLogoGetsTwoColors() {
        let q = logo(TestImages.circle(antialias: true))
        #expect(q.palette.count == 2)
        let labs = q.palette.map { Lab($0) }
        #expect(labs.contains { $0.distance(to: Lab(TestImages.red)) < 3 })
        #expect(labs.contains { $0.distance(to: Lab(TestImages.white)) < 3 })
    }

    @Test func nearestColorIsChosenInLab() {
        let b = Bitmap(width: 2, height: 1) { x, _ in x == 0 ? RGBA(100, 100, 100) : RGBA(200, 200, 200) }
        let q = Quantizer.assign(b, palette: [TestImages.black, TestImages.white], alphaThreshold: 128)
        #expect(q.indices == [0, 1])
    }

    // Review focus: transparent-background logo.
    @Test func transparentPixelsAreExcluded() {
        let q = logo(TestImages.circle(bg: .clear, antialias: true))
        #expect(q.palette.count == 1)
        #expect(q.indices[0] == -1)
        #expect(q.indices[24 * 48 + 24] == 0)
    }

    // Review focus: JPEG-compressed logo.
    @Test func jpegLikeNoiseDoesNotAddColors() {
        let q = logo(TestImages.noisy(TestImages.circle(antialias: true), amplitude: 3))
        #expect(q.palette.count == 2)
    }

    // Review focus: JPEG chroma subsampling leaves fringe colors that sit off the straight blend line.
    @Test func chromaFringesAreNotPaletteColors() {
        let fringe = RGBA(254, 252, 216)   // measured on a real JPEG edge between white and orange
        let orange = RGBA(241, 166, 26)
        let b = Bitmap(width: 64, height: 64) { x, _ in x < 31 ? TestImages.white : (x == 31 ? fringe : orange) }
        #expect(logo(b).palette.count == 2)
    }

    @Test func colorCountCapsPaletteKeepingMostFrequent() {
        let b = TestImages.grid(["WWWWRRRB", "WWWWRRRG"], scale: 4)
        let q = logo(b, colors: 2)
        #expect(Set(q.palette) == [TestImages.white, TestImages.red])
    }

    @Test func largeMidtoneAreaIsKeptEvenOnABlendLine() {
        let gray = RGBA(128, 128, 128)
        let b = Bitmap(width: 64, height: 8) { x, _ in x < 24 ? TestImages.black : (x < 40 ? gray : TestImages.white) }
        #expect(logo(b).palette.count == 3)
    }

    // Regression: a small flat gray panel between black and white sits on their blend line but is a
    // real color (it has flat interior pixels; anti-aliasing blends don't).
    @Test func smallFlatMidtonePanelIsARealColor() {
        let gray = RGBA(60, 60, 62)
        let b = Bitmap(width: 100, height: 100) { x, y in
            if (10..<22).contains(x) && (10..<22).contains(y) { return gray }   // 1.4% share
            if (40..<90).contains(x) && (40..<60).contains(y) { return TestImages.white }
            return TestImages.black
        }
        #expect(logo(b).palette.contains(gray))
    }

    // Regression (UI screenshot): a dark panel a few ΔE lighter than the background is a real,
    // flat color — not noise to be merged into the background.
    @Test func subtleFlatColorsStaySeparate() {
        let bg = RGBA(30, 30, 30), panel = RGBA(42, 42, 44)
        let b = Bitmap(width: 120, height: 80) { x, y in (20..<100).contains(x) && (15..<65).contains(y) ? panel : bg }
        #expect(Lab(bg).distance(to: Lab(panel)) < 10)   // within the merge distance
        #expect(Set(logo(b).palette) == [bg, panel])
    }

    // Regression: an anti-aliased pixel between a dark stroke and a light fill must join one of
    // those two, not a third palette color that happens to be numerically nearer.
    @Test func blendPixelsJoinTheColorsTheyBlend() {
        let stroke = RGBA(80, 80, 82), fill = RGBA(204, 204, 210), otherFill = RGBA(178, 178, 184)
        let blend = RGBA(170, 170, 175)   // ~73% of the way from stroke to fill: nearest is otherFill
        let b = Bitmap(width: 30, height: 10) { x, _ in
            if x < 10 { return otherFill }   // elsewhere in the image
            if x < 18 { return stroke }
            if x == 18 { return blend }
            return fill
        }
        let q = Quantizer.assign(b, palette: [stroke, fill, otherFill], alphaThreshold: 128)
        let refined = Quantizer.refineBlends(q, b)
        #expect(q.indices[18] == 2)                       // plain nearest-color picks the third color…
        #expect([0, 1].contains(refined.indices[18]))     // …refinement picks stroke or fill
        #expect(refined.indices[5] == 2)                  // real otherFill pixels are untouched
    }

    @Test func fullyTransparentImageHasEmptyPalette() {
        let q = logo(Bitmap(width: 4, height: 4) { _, _ in .clear })
        #expect(q.palette.isEmpty && q.indices.allSatisfy { $0 == -1 })
    }
}
