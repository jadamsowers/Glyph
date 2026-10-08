import Testing
@testable import VectorEngine

@Suite struct SegmentTests {
    func segment(_ rows: [String], speck: Int = 0) -> Segmentation {
        Segmenter.segment(TestImages.quantized(rows), params: SegmentParams(speckSize: speck))
    }

    @Test func sameColorPiecesThatDoNotTouchAreSeparate() {
        let s = segment(["RWR"])
        #expect(s.regions.count == 3)
        #expect(s.label(0, 0) != s.label(2, 0))
    }

    // Review focus: same-colored pixels touching only diagonally.
    @Test func diagonalNeighborsAreNotConnected() {
        let s = segment(["RW", "WR"])
        #expect(s.regions.count == 4)
    }

    @Test func specksMergeIntoTheirNeighbor() {
        let rows = (0..<20).map { y in
            String((0..<20).map { x -> Character in
                (x == 2 && y == 2) || ((10..<15).contains(x) && (10..<15).contains(y)) ? "K" : "W"
            })
        }
        let s = segment(rows, speck: 4)
        #expect(s.regions.count == 2)
        #expect(s.regions.map(\.pixelCount).sorted() == [25, 375])
        #expect(s.label(2, 2) == s.label(0, 0))
    }

    @Test func speckMergesIntoMostSimilarColor() {
        // A one-pixel blue speck between red and white joins whichever neighbor is closer in Lab.
        let s = segment(["RRRRBWWWW"], speck: 2)
        let dRed = Lab(TestImages.blue).distance(to: Lab(TestImages.red))
        let dWhite = Lab(TestImages.blue).distance(to: Lab(TestImages.white))
        let expected = dRed < dWhite ? s.label(0, 0) : s.label(8, 0)
        #expect(s.label(4, 0) == expected)
        #expect(s.regions.count == 2)
    }

    @Test func speckTouchingOnlyTransparencyIsKept() {
        let s = segment(["...", ".R.", "..."], speck: 4)
        #expect(s.regions.count == 1)
        #expect(s.label(1, 1) == 0 && s.label(0, 0) == -1)
    }

    @Test func outsideTheImageIsNone() {
        let s = segment(["R"])
        #expect(s.label(-1, 0) == -1 && s.label(0, 1) == -1 && s.label(0, 0) == 0)
    }

    @Test func largeUniformImageDoesNotOverflowTheStack() {
        let q = QuantizedImage(width: 600, height: 600, palette: [TestImages.white], indices: [Int32](repeating: 0, count: 360_000))
        let s = Segmenter.segment(q, params: SegmentParams(speckSize: 4))
        #expect(s.regions == [Region(color: TestImages.white, pixelCount: 360_000)])
    }
}
