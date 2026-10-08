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

    @Test func fullyTransparentImageHasEmptyPalette() {
        let q = logo(Bitmap(width: 4, height: 4) { _, _ in .clear })
        #expect(q.palette.isEmpty && q.indices.allSatisfy { $0 == -1 })
    }
}
