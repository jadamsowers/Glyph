import CoreGraphics
import Foundation
import Testing
@testable import VectorEngine

@Suite struct CoreTests {
    @Test func labOfWhiteAndBlack() {
        let w = Lab(RGBA(255, 255, 255))
        #expect(abs(w.l - 100) < 0.01)
        #expect(abs(w.a) < 0.05 && abs(w.b) < 0.05)
        #expect(abs(Lab(RGBA(0, 0, 0)).l) < 0.01)
    }

    @Test func labOfPureRed() {
        let r = Lab(RGBA(255, 0, 0))
        #expect(abs(r.l - 53.24) < 0.05)
        #expect(abs(r.a - 80.09) < 0.1)
        #expect(abs(r.b - 67.20) < 0.1)
    }

    @Test func hexString() {
        #expect(RGBA(255, 16, 0).hex == "#ff1000")
    }

    @Test func segmentDistance() {
        #expect(Vec2(5, 3).distance(toSegment: Vec2(0, 0), Vec2(10, 0)) == 3)
        #expect(Vec2(-4, 3).distance(toSegment: Vec2(0, 0), Vec2(10, 0)) == 5)
    }

    @Test func bitmapRoundTripsThroughCGImage() {
        let src = Bitmap(width: 3, height: 2) { x, y in
            x == 2 && y == 1 ? RGBA(200, 100, 50, 128) : RGBA(UInt8(x * 80), UInt8(y * 200), 7)
        }
        let back = Bitmap(cgImage: src.makeCGImage())
        #expect(back.width == 3 && back.height == 2)
        for y in 0..<2 { for x in 0..<3 where !(x == 2 && y == 1) { #expect(back[x, y] == src[x, y]) } }
        let semi = back[2, 1]
        #expect(semi.a == 128)
        #expect(abs(Int(semi.r) - 200) <= 2 && abs(Int(semi.g) - 100) <= 2 && abs(Int(semi.b) - 50) <= 2)
    }

    @Test func renderUsesTopDownRows() {
        let b = Bitmap.render(width: 4, height: 4) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        }
        #expect(b[0, 0] == RGBA(255, 0, 0))
        #expect(b[0, 3] == .clear)
    }

    // Review focus: very large image is downscaled but remembers its original size.
    @Test func inputImageDownscalesLongSide() {
        let big = Bitmap(width: 100, height: 50) { _, _ in RGBA(10, 20, 30) }
        let input = InputImage(cgImage: big.makeCGImage(), maxDimension: 40)
        #expect(input.bitmap.width == 40 && input.bitmap.height == 20)
        #expect(input.originalWidth == 100 && input.originalHeight == 50)
        #expect(input.scaleX == 2.5 && input.scaleY == 2.5)
    }

    @Test func inputImageNeverUpscales() {
        let small = Bitmap(width: 10, height: 10) { _, _ in RGBA(1, 2, 3) }
        let input = InputImage(cgImage: small.makeCGImage(), maxDimension: 2000)
        #expect(input.bitmap.width == 10 && input.scaleX == 1)
    }

    @Test func smallImagesAreUpscaledToTheMinimumSize() {
        let small = Bitmap(width: 60, height: 30) { _, _ in RGBA(1, 2, 3) }
        let input = InputImage(cgImage: small.makeCGImage(), maxDimension: 2000, minDimension: 256)
        #expect(input.upscale == 8)   // ⌈512 / 60⌉ = 9, capped at 8
        #expect(input.bitmap.width == 480 && input.bitmap.height == 240)
        #expect(input.originalWidth == 60 && input.scaleX == 0.125)
        let mid = InputImage(cgImage: Bitmap(width: 200, height: 100) { _, _ in RGBA(1, 2, 3) }.makeCGImage(), maxDimension: 2000, minDimension: 256)
        #expect(mid.upscale == 4)     // ⌈512 / 200⌉ = 3, raised to the minimum of 4
        let large = InputImage(cgImage: Bitmap(width: 300, height: 100) { _, _ in RGBA(1, 2, 3) }.makeCGImage(), maxDimension: 2000, minDimension: 256)
        #expect(large.upscale == 1)   // at or above the threshold: untouched
        let tiny = InputImage(cgImage: Bitmap(width: 20, height: 20) { _, _ in RGBA(1, 2, 3) }.makeCGImage(), maxDimension: 2000, minDimension: 256)
        #expect(tiny.upscale == 8)   // capped
    }

    @Test func bicubicUpscaleSmoothsAnEdge() {
        let edge = Bitmap(width: 4, height: 1) { x, _ in x < 2 ? RGBA(0, 0, 0) : RGBA(255, 255, 255) }
        let up = edge.upscaled(by: 8)
        let row = (0..<32).map { Int(up[$0, 0].r) }
        #expect(row == row.sorted())                                // monotone ramp, no overshoot
        #expect(row.filter { $0 > 20 && $0 < 235 }.count >= 4)      // with intermediate values
    }

    @Test func unreadableFileThrows() {
        #expect(throws: VectorEngineError.self) {
            try InputImage.load(contentsOf: URL(fileURLWithPath: "/nonexistent/x.png"), maxDimension: 100)
        }
    }
}
