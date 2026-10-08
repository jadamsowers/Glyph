import CoreGraphics
import Foundation
import Testing
@testable import VectorEngine

@Suite struct PerceptualTests {
    func run(_ b: Bitmap, _ o: Options = Options()) throws -> PipelineState {
        try Pipeline.run(input: InputImage(bitmap: b), options: o)
    }

    // MARK: Level 1 — contrast-weighted tolerance

    @Test func contrastMultiplierFollowsColorDifference() {
        #expect(Perceptual.toleranceMultiplier(RGBA(0, 0, 0), RGBA(255, 255, 255), reference: 30) == 1)
        #expect(Perceptual.toleranceMultiplier(RGBA(120, 120, 120), RGBA(130, 130, 130), reference: 30) > 2)
        #expect(Perceptual.toleranceMultiplier(RGBA(120, 120, 120), RGBA(121, 121, 121), reference: 30) == 4)   // capped
        #expect(Perceptual.toleranceMultiplier(RGBA(10, 10, 10), nil, reference: 30) == 1)                      // transparency
    }

    @Test func lowContrastEdgesAreSimplifiedMoreHighContrastOnesAlike() throws {
        var off = Options(); off.advanced.contrastWeighting = false
        let photo = TestImages.photoLike()
        #expect(try run(photo).result!.stats.segmentCount < run(photo, off).result!.stats.segmentCount)
        let logo = TestImages.circle(size: 64, radius: 22, antialias: true)
        #expect(try run(logo).result!.stats.segmentCount == run(logo, off).result!.stats.segmentCount)
    }

    @Test func lowContrastSpecksMergeMoreReadily() throws {
        // Two 6-px specks on gray: one nearly gray (ΔE small), one black. Speck size 4.
        let b = Bitmap(width: 40, height: 20) { x, y in
            if (5..<8).contains(x) && (5..<7).contains(y) { return RGBA(132, 128, 128) }
            if (25..<28).contains(x) && (5..<7).contains(y) { return RGBA(0, 0, 0) }
            return RGBA(128, 128, 128)
        }
        let q = Quantizer.assign(b, palette: [RGBA(128, 128, 128), RGBA(132, 128, 128), RGBA(0, 0, 0)], alphaThreshold: 128)
        var p = SegmentParams(speckSize: 4)
        p.contrastReference = 30
        #expect(Segmenter.segment(q, params: p).regions.count == 2)   // the faint speck merged, the black one kept
        #expect(Segmenter.segment(q, params: SegmentParams(speckSize: 4)).regions.count == 3)
    }

    // MARK: Level 2 — display size

    @Test func smallDisplaySizeSimplifiesAndDropsDecimals() throws {
        let b = TestImages.circle(size: 400, radius: 150, antialias: true)
        let full = try #require(try run(b).result)
        let small = try #require(try run(b, Options(displaySize: 32)).result)
        #expect(small.stats.segmentCount <= full.stats.segmentCount)
        #expect(small.stats.byteCount < full.stats.byteCount)
        let pathData = small.svg.components(separatedBy: "d=\"").dropFirst().map { $0.prefix { $0 != "\"" } }.joined()
        #expect(!pathData.contains("."))   // at 1/12 scale, sub-pixel coordinates are invisible
        #expect(small.width == 400)        // output stays at the original size
    }

    // MARK: Level 3 — Simplify

    @Test func simplifyReducesSegmentsMonotonicallyAndStaysGapFree() throws {
        let b = TestImages.photoLike(size: 64)
        var counts: [Int] = []
        for level in [0.0, 0.5, 1.0] {
            var o = Options(tracing: .sharedEdges, simplify: level)
            o.advanced.contrastWeighting = false
            let s = try run(b, o)
            let r = try #require(s.result)
            counts.append(r.stats.segmentCount)
            let raster = ShapeRenderer.rasterize(r.shapes, width: 64, height: 64, antialias: false, background: TestImages.magenta)
            #expect(!raster.pixels.contains(TestImages.magenta), "gap at simplify \(level)")
        }
        #expect(counts[0] > counts[1] && counts[1] > counts[2], "\(counts)")
    }

    @Test func simplifyNeverCutsTheImageBorder() throws {
        let b = TestImages.photoLike(size: 64)
        var o = Options(tracing: .sharedEdges, simplify: 1)
        o.advanced.contrastWeighting = false
        let r = try #require(try run(b, o).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 64, height: 64, antialias: false, background: TestImages.magenta)
        for (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63)] { #expect(raster[x, y] != TestImages.magenta, "corner (\(x),\(y)) uncovered") }
    }

    @Test func simplifyZeroChangesNothing() throws {
        let b = TestImages.photoLike(size: 48)
        #expect(try run(b).result!.svg == run(b, Options(simplify: 0)).result!.svg)
    }

    @Test func visibleDifferenceIsReportedAndGrowsWithSimplify() throws {
        let b = TestImages.photoLike(size: 64)
        let none = try #require(try run(b).result).stats.visibleDifference
        let lots = try #require(try run(b, Options(simplify: 1)).result).stats.visibleDifference
        #expect(none >= 0 && none < 0.5)
        #expect(lots > none)
    }
}

extension PerceptualTests {
    // Regression: the seam underlay must be at least one display pixel wide when shown small.
    @Test func seamUnderlayCoversADisplayPixel() throws {
        let r = try #require(try run(TestImages.photoLike(size: 64), Options(tracing: .stacked, displaySize: 16)).result)
        #expect(r.seamStroke >= 4)   // 64 px shown at 16 px: one display pixel = 4 output px
    }
}
