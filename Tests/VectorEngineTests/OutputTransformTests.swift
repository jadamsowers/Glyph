import Foundation
import Testing
@testable import VectorEngine

@Suite struct OutputTransformTests {
    /// 40×20, white with a red block at the left (x 2…10, y 4…12).
    let image = Bitmap(width: 40, height: 20) { x, y in (2..<10).contains(x) && (4..<12).contains(y) ? TestImages.red : TestImages.white }

    func redCenter(_ configure: (inout Options) -> Void) throws -> (VectorResult, Vec2) {
        var o = Options(); configure(&o)
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: image), options: o).result)
        let red = try #require(r.shapes.first { $0.color == TestImages.red })
        let pts = red.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) }
        // Bounding-box center (anchor averages are skewed by uneven anchor spacing).
        let c = Vec2((pts.map(\.x).min()! + pts.map(\.x).max()!) / 2, (pts.map(\.y).min()! + pts.map(\.y).max()!) / 2)
        return (r, c)
    }

    @Test func flips() throws {
        let (r0, c0) = try redCenter { _ in }
        #expect(r0.width == 40 && abs(c0.x - 6) < 0.5 && abs(c0.y - 8) < 0.5)
        let (_, h) = try redCenter { $0.flipHorizontal = true }
        #expect(abs(h.x - 34) < 0.5 && abs(h.y - 8) < 0.5)
        let (_, v) = try redCenter { $0.flipVertical = true }
        #expect(abs(v.x - 6) < 0.5 && abs(v.y - 12) < 0.5)
    }

    @Test func rotateClockwise() throws {
        let (r, c) = try redCenter { $0.rotation = 90 }
        #expect(r.width == 20 && r.height == 40)
        #expect(abs(c.x - 12) < 0.5 && abs(c.y - 6) < 0.5)   // (x, y) → (H − y, x)
        #expect(r.svg.contains("viewBox=\"0 0 20 40\""))
    }

    @Test func dpiSetsPhysicalSize() throws {
        let (r, _) = try redCenter { $0.dpi = 72 }
        #expect(r.svg.contains("width=\"0.556in\"") && r.svg.contains("height=\"0.278in\""))
        #expect(r.svg.contains("viewBox=\"0 0 40 20\""))
    }
}
