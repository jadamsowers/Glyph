import Foundation
import Testing
@testable import VectorEngine

@Suite struct HalftoneTests {
    func run(_ b: Bitmap, _ h: Halftone) throws -> VectorResult {
        var o = Options(); o.halftone = h
        return try #require(try Pipeline.run(input: InputImage(bitmap: b), options: o).result)
    }

    /// Dot (center, radius) from each 4-cubic circle subpath.
    func dots(_ r: VectorResult) -> [(Vec2, Double)] {
        r.shapes.flatMap(\.subpaths).map { sp in
            let pts = [sp.start] + sp.segments.map(\.end)
            let c = Vec2((pts.map(\.x).min()! + pts.map(\.x).max()!) / 2, (pts.map(\.y).min()! + pts.map(\.y).max()!) / 2)
            return (c, (pts.map(\.x).max()! - pts.map(\.x).min()!) / 2)
        }
    }

    @Test func dotSizeFollowsDarknessAndWhiteHasNone() throws {
        let ramp = Bitmap(width: 120, height: 40) { x, _ in let v = UInt8(255 - min(255, x * 255 / 100)); return RGBA(v, v, v) }
        let d = dots(try run(ramp, Halftone(cellSize: 8, angle: 0)))
        let left = d.filter { $0.0.x < 30 }.map(\.1), right = d.filter { $0.0.x > 80 }.map(\.1)
        #expect(!right.isEmpty)
        let leftMean: Double = left.isEmpty ? 0 : left.reduce(0, +) / Double(left.count)
        let rightMean: Double = right.reduce(0, +) / Double(right.count)
        #expect(leftMean < rightMean)
        #expect(!d.contains { $0.0.x < 4 })   // the white edge gets no dots
    }

    @Test func densityMatchesCellSize() throws {
        let black = Bitmap(width: 80, height: 80) { _, _ in TestImages.black }
        let n = dots(try run(black, Halftone(cellSize: 8, angle: 0))).count
        #expect(abs(n - 100) <= 20, "\(n) dots for a 10×10 grid")
    }

    @Test func angleZeroAlignsRows() throws {
        let gray = Bitmap(width: 64, height: 64) { _, _ in RGBA(128, 128, 128) }
        let ys = Set(dots(try run(gray, Halftone(cellSize: 8, angle: 0))).map { ($0.0.y * 10).rounded() })
        #expect(ys.count <= 9)
        let tilted = Set(dots(try run(gray, Halftone(cellSize: 8, angle: 45))).map { ($0.0.y * 10).rounded() })
        #expect(tilted.count > ys.count)
    }

    @Test func lineStyleEmitsPolygons() throws {
        let gray = Bitmap(width: 64, height: 64) { _, _ in RGBA(100, 100, 100) }
        let r = try run(gray, Halftone(cellSize: 8, angle: 30, shape: .line))
        #expect(!r.shapes.isEmpty)
        #expect(r.shapes.allSatisfy { $0.subpaths.allSatisfy { $0.segments.allSatisfy { if case .line = $0 { true } else { false } } } })
        #expect(XMLParser(data: Data(r.svg.utf8)).parse())
    }
}
