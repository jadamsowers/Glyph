import Testing
@testable import VectorEngine

@Suite struct TopologyTests {
    func topo(_ rows: [String]) -> (Segmentation, Topology) {
        let seg = Segmenter.segment(TestImages.quantized(rows), params: SegmentParams(speckSize: 0))
        return (seg, Topology.build(seg))
    }

    /// Loops must chain end-to-start and their signed areas must add up to the region's pixel count.
    func checkInvariants(_ seg: Segmentation, _ t: Topology, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(t.regions.count == seg.regions.count, sourceLocation: sourceLocation)
        for (r, region) in t.regions.enumerated() {
            #expect(-region.areas.reduce(0, +) == Double(seg.regions[r].pixelCount), "region \(r)", sourceLocation: sourceLocation)
            for loop in region.loops {
                let pieces = loop.map { t.points($0) }
                for (i, p) in pieces.enumerated() {
                    #expect(p.last == pieces[(i + 1) % pieces.count].first, sourceLocation: sourceLocation)
                }
            }
        }
    }

    /// Crack edges counted directly from the labels.
    func crackEdgeCount(_ s: Segmentation) -> Int {
        var n = 0
        for y in 0...s.height { for x in 0..<s.width where s.label(x, y - 1) != s.label(x, y) { n += 1 } }
        for y in 0..<s.height { for x in 0...s.width where s.label(x - 1, y) != s.label(x, y) { n += 1 } }
        return n
    }

    @Test func singlePixelIsOneClosedLoop() {
        let (seg, t) = topo(["R"])
        #expect(t.chains.count == 1)
        #expect(t.chains[0].isClosed && t.chains[0].points.count == 5)
        #expect(t.regions[0].loops.count == 1 && t.regions[0].outerArea == 1)
        checkInvariants(seg, t)
    }

    @Test func randomBlocksSatisfyInvariantsAndUseEveryEdgeOnce() {
        for seed: UInt64 in [1, 2, 3] {
            let b = TestImages.randomBlocks(seed: seed)
            let q = Quantizer.assign(b, palette: [TestImages.red, TestImages.blue, TestImages.white], alphaThreshold: 128)
            let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 0))
            let t = Topology.build(seg)
            checkInvariants(seg, t)
            #expect(t.chains.reduce(0) { $0 + $1.points.count - 1 } == crackEdgeCount(seg))
        }
    }

    @Test func checkerboardCenterIsAJunction() {
        let (seg, t) = topo(["RW", "WR"])
        #expect(t.chains.allSatisfy { !$0.isClosed })
        #expect(t.regions.allSatisfy { $0.loops.count == 1 })
        checkInvariants(seg, t)
    }

    // Review focus: a region whose holes touch diagonally at one lattice vertex.
    @Test func regionTouchingItselfDiagonally() {
        let (seg, t) = topo(["WWWW", "WWRW", "WBWW", "WWWW"])
        let white = Int(seg.label(0, 0))
        #expect(t.regions[white].loops.count == 2)   // outer + one hole around the diagonal R/B pair
        #expect(t.regions[white].outerArea == 16)
        checkInvariants(seg, t)
    }

    @Test func ringHasOuterLoopAndHole() {
        let (seg, t) = topo(["WWWWW", "WRRRW", "WRBRW", "WRRRW", "WWWWW"])
        let ring = Int(seg.label(1, 1))
        #expect(t.regions[ring].loops.count == 2)
        #expect(t.regions[ring].outerArea == 9)
        checkInvariants(seg, t)
    }

    @Test func transparencyGetsNoRegion() {
        let (seg, t) = topo(["..", ".R"])
        #expect(t.regions.count == 1)
        #expect(t.chains.count == 1 && t.chains[0].isClosed)
        checkInvariants(seg, t)
    }

    @Test func stripesProduceOpenChainsBetweenBorderJunctions() {
        let (seg, t) = topo(["RWB", "RWB"])
        let rw = t.chains.filter { Set([$0.left, $0.right]) == Set([seg.label(0, 0), seg.label(1, 0)]) }
        #expect(rw.count == 1 && !rw[0].isClosed)
        #expect(Set([rw[0].points.first!, rw[0].points.last!]) == [LatticePoint(1, 0), LatticePoint(1, 2)])
        checkInvariants(seg, t)
    }
}
