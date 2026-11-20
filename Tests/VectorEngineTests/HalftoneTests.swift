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

    // Cell size is measured on the image as if scaled down to `Halftone.referenceSize`: a camera
    // photo gets the screen a smaller copy of it would, not hundreds of thousands of dots.
    @Test func largeImagesGetTheScreenOfASmallerCopy() throws {
        // A camera photo arrives already scaled down for processing: 1000 px standing in for 3000.
        let gray = Bitmap(width: 1000, height: 1000) { _, _ in RGBA(100, 100, 100) }
        var o = Options(); o.halftone = Halftone(cellSize: 8, angle: 0)
        let small = dots(try run(gray, o.halftone!))
        let large = dots(try #require(try Pipeline.run(input: InputImage(bitmap: gray, originalWidth: 3000, originalHeight: 3000),
                                                       options: o).result))
        #expect(abs(large.count - small.count) <= small.count / 20, "\(small.count) dots at 1000 px, \(large.count) at 3000 px")
        // Same pattern, three times the size.
        let r = small.map(\.1).sorted(), R = large.map(\.1).sorted()
        #expect(abs(R[R.count / 2] - 3 * r[r.count / 2]) < 1)
    }

    // Dark dots are sized to overlap so dark areas go solid. Under the even-odd rule one path of
    // dots cancels where two overlap; each dot is its own shape, so overlaps stay ink — in the
    // canvas and in the SVG (one <path> per dot). Separate small paths also draw in time
    // proportional to the dots, where one huge path slows down far faster than that.
    @Test func overlappingDotsStayInk() throws {
        let black = Bitmap(width: 80, height: 80) { _, _ in TestImages.black }
        let r = try run(black, Halftone(cellSize: 20, angle: 0))
        // Dots centered at x = 30 and 50 (row y = 30) overlap between x ≈ 38.7 and 41.3.
        let raster = ShapeRenderer.rasterize(r.shapes, width: 80, height: 80, antialias: false)
        #expect(raster[39, 29].a == 255)
        #expect(r.svg.components(separatedBy: "<path").count - 1 == dots(r).count)
    }

    // However small the cell, the screen stays within a budget the canvas can draw interactively.
    @Test func screenStaysWithinTheDotBudget() throws {
        let black = Bitmap(width: 1000, height: 750) { _, _ in TestImages.black }
        let n = dots(try run(black, Halftone(cellSize: 2, angle: 0))).count
        #expect(n <= Halftone.maxCells + Halftone.maxCells / 20, "\(n) dots")
        #expect(n >= Halftone.maxCells * 3 / 4, "\(n) dots")
    }

    // The seam underlay hides gaps between neighboring traced shapes. A halftone is one shape: an
    // underlay would only grow every dot (darkening light areas) and double the drawing.
    @Test func screenHasNoSeamUnderlay() throws {
        let gray = Bitmap(width: 64, height: 64) { _, _ in RGBA(128, 128, 128) }
        var o = Options(tracing: .stacked); o.halftone = Halftone(cellSize: 8)
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: gray), options: o).result)
        #expect(r.seamStroke == 0)
        #expect(!r.svg.contains("stroke"))
    }

    @Test func lineStyleEmitsPolygons() throws {
        let gray = Bitmap(width: 64, height: 64) { _, _ in RGBA(100, 100, 100) }
        let r = try run(gray, Halftone(cellSize: 8, angle: 30, shape: .line))
        #expect(!r.shapes.isEmpty)
        #expect(r.shapes.allSatisfy { $0.subpaths.allSatisfy { $0.segments.allSatisfy { if case .line = $0 { true } else { false } } } })
        #expect(XMLParser(data: Data(r.svg.utf8)).parse())
    }
}
