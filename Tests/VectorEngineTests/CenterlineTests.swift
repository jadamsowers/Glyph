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

    // Thinning visits only the ink border; it must match a plain scan of every pixel, including on
    // blobs much thicker than strokes (a thresholded photo) and ink touching the image edge.
    @Test func borderThinningMatchesFullScan() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<20 {
            let w = Int.random(in: 8...60, using: &rng), h = Int.random(in: 8...60, using: &rng)
            let blobs = (0..<Int.random(in: 1...6, using: &rng)).map { _ in
                (Double.random(in: 0...Double(w), using: &rng), Double.random(in: 0...Double(h), using: &rng),
                 Double.random(in: 2...20, using: &rng))
            }
            let mask = (0..<w * h).map { i in
                let x = Double(i % w), y = Double(i / w)
                return blobs.contains { (x - $0.0) * (x - $0.0) + (y - $0.1) * (y - $0.1) < $0.2 * $0.2 }
                    || Int.random(in: 0..<25, using: &rng) == 0
            }
            let thinned = Centerline.thin(mask, w, h)
            #expect(thinned == Self.fullScanThin(mask, w, h))
            #expect(Centerline.removeCorners(thinned, w, h) == Self.groupingRemoveCorners(thinned, w, h))
            #expect(Centerline.removeCorners(mask, w, h) == Self.groupingRemoveCorners(mask, w, h))
        }
    }

    /// Corner removal as originally written, growing the neighbor group explicitly.
    static func groupingRemoveCorners(_ sk: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var m = sk
        func px(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        var changed = true
        while changed {
            changed = false
            for y in 0..<h {
                for x in 0..<w where m[y * w + x] {
                    let set = Centerline.offsets.filter { px(x + $0.0, y + $0.1) }
                    guard set.count >= 2 && set.count <= 3 else { continue }
                    var group = [set[0]], rest = Array(set.dropFirst())
                    var grew = true
                    while grew {
                        grew = false
                        for (k, r) in rest.enumerated().reversed() where group.contains(where: { abs($0.0 - r.0) <= 1 && abs($0.1 - r.1) <= 1 }) {
                            group.append(r); rest.remove(at: k); grew = true
                        }
                    }
                    if rest.isEmpty { m[y * w + x] = false; changed = true }
                }
            }
        }
        return m
    }

    /// Zhang–Suen as originally written: every pixel, every pass.
    static func fullScanThin(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var m = mask
        func px(_ x: Int, _ y: Int) -> Int { x < 0 || y < 0 || x >= w || y >= h ? 0 : (m[y * w + x] ? 1 : 0) }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var remove: [Int] = []
                for y in 0..<h {
                    for x in 0..<w where m[y * w + x] {
                        let n = [px(x, y - 1), px(x + 1, y - 1), px(x + 1, y), px(x + 1, y + 1),
                                 px(x, y + 1), px(x - 1, y + 1), px(x - 1, y), px(x - 1, y - 1)]
                        let b = n.reduce(0, +)
                        guard b >= 2 && b <= 6 else { continue }
                        var a = 0
                        for i in 0..<8 where n[i] == 0 && n[(i + 1) % 8] == 1 { a += 1 }
                        guard a == 1 else { continue }
                        let ok = pass == 0
                            ? n[0] * n[2] * n[4] == 0 && n[2] * n[4] * n[6] == 0
                            : n[0] * n[2] * n[6] == 0 && n[0] * n[4] * n[6] == 0
                        if ok { remove.append(y * w + x) }
                    }
                }
                for i in remove { m[i] = false }
                if !remove.isEmpty { changed = true }
            }
        }
        return m
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
