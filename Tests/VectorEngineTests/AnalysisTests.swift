import Testing
@testable import VectorEngine

@Suite struct AnalysisTests {
    func analyze(_ b: Bitmap) -> Analysis { Analyzer.analyze(b, params: ClassifierParams()) }

    @Test func flatLogoIsLogo() {
        let a = analyze(TestImages.circle(size: 96, radius: 32, antialias: true))
        #expect(a.kind == .logo)
        #expect(a.significantColors == 2)
    }

    // Review focus: JPEG-compressed logo.
    @Test func jpegNoisyLogoIsLogo() {
        let a = analyze(TestImages.noisy(TestImages.circle(size: 96, radius: 32, antialias: true), amplitude: 3))
        #expect(a.kind == .logo)
        #expect(a.significantColors == 2)
    }

    // Review focus: transparent-background logo.
    @Test func transparentLogoIsLogo() {
        let a = analyze(TestImages.circle(size: 96, radius: 32, bg: .clear, antialias: true))
        #expect(a.kind == .logo && a.significantColors == 1)
    }

    @Test func texturedGradientIsPhoto() {
        #expect(analyze(TestImages.photoLike()).kind == .photo)
    }

    @Test func smoothGradientIsPhoto() {
        let b = Bitmap(width: 64, height: 64) { x, _ in RGBA(UInt8(x * 4), 80, UInt8(255 - x * 4)) }
        #expect(analyze(b).kind == .photo)
    }

    @Test func kmeansFindsTheUnderlyingColors() {
        let base = TestImages.grid(["RRBB", "RRBB", "GGGG"], scale: 12)
        var p = QuantizeParams(kind: .photo, colorCount: 3)
        p.kmeansIterations = 12
        let q = Quantizer.photo(TestImages.noisy(base, amplitude: 10), params: p)
        #expect(q.palette.count == 3)
        for c in [TestImages.red, TestImages.blue, TestImages.green] {
            #expect(q.palette.contains { Lab($0).distance(to: Lab(c)) < 6 })
        }
    }

    @Test func kmeansIsDeterministic() {
        let b = TestImages.photoLike()
        let p = QuantizeParams(kind: .photo, colorCount: 8)
        #expect(Quantizer.photo(b, params: p) == Quantizer.photo(b, params: p))
    }

    @Test func bilateralSmoothsNoiseButKeepsEdges() {
        let step = Bitmap(width: 32, height: 16) { x, _ in x < 16 ? RGBA(40, 40, 40) : RGBA(220, 220, 220) }
        let noisy = TestImages.noisy(step, amplitude: 12)
        let out = Prefilter.bilateral(noisy, radius: 2, sigmaColor: 24, alphaThreshold: 128)
        func meanDeviation(_ b: Bitmap) -> Double {
            var s = 0
            for y in 0..<16 { for x in 0..<12 { s += abs(Int(b[x, y].r) - 40) } }
            return Double(s) / Double(16 * 12)
        }
        #expect(meanDeviation(out) < meanDeviation(noisy) * 0.6)
        for y in 0..<16 {
            #expect(abs(Int(out[14, y].r) - 40) < 20)
            #expect(abs(Int(out[17, y].r) - 220) < 20)
        }
    }

    let logo = Analysis(kind: .logo, significantColors: 5, gradientFraction: 0.02, palette: [], shares: [])
    let photo = Analysis(kind: .photo, significantColors: 33, gradientFraction: 0.6, palette: [], shares: [])

    @Test func logoDefaults() {
        let r = Options().resolved(with: logo)
        #expect(r.kind == .logo && r.output.tracing == .sharedEdges && !r.prefilter.enabled)
        #expect(r.quantize.colorCount == 5 && r.segment.speckSize == 4)
    }

    @Test func photoDefaults() {
        let r = Options().resolved(with: photo)
        #expect(r.kind == .photo && r.output.tracing == .stacked && r.prefilter.enabled)
        #expect(r.quantize.colorCount == 16 && r.segment.speckSize == 24)
    }

    @Test func explicitChoicesWin() {
        let o = Options(kind: .photo, tracing: .sharedEdges, colorCount: 7, speckSize: 0)
        let r = o.resolved(with: logo)
        #expect(r.kind == .photo && r.output.tracing == .sharedEdges && r.prefilter.enabled)
        #expect(r.quantize.colorCount == 7 && r.segment.speckSize == 0)
    }

    @Test func detailAndSmoothnessMapToTolerances() {
        var o = Options(detail: 1, smoothness: 0)
        let r = o.resolved(with: logo)
        #expect(abs(r.polygon.tolerance - 0.4) < 1e-9 && abs(r.curve.tolerance - 0.5) < 1e-9)
        #expect(r.polygon.cornerAngle == 30)
        o.advanced.polygonTolerance = 3
        #expect(o.resolved(with: logo).polygon.tolerance == 3)
    }
}
