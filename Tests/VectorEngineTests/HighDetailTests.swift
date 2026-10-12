import CoreGraphics
import Foundation
import Testing
@testable import VectorEngine

@Suite struct HighDetailTests {
    /// A 300 px image with a tiny anti-aliased five-point star (outer radius 4 px) in navy.
    func tinyStar() -> CGImage {
        Bitmap.render(width: 300, height: 300) { ctx in
            ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.16, blue: 0.36, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 50, width: 200, height: 40))   // a big shape too
            let path = CGMutablePath()
            for i in 0..<10 {
                let a = Double(i) * .pi / 5 - .pi / 2, r = i % 2 == 0 ? 4.0 : 1.7
                let p = CGPoint(x: 150 + r * cos(a), y: 200 + r * sin(a))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }.makeCGImage()
    }

    @Test func upscalesLargeImagesWithinALimit() {
        let img = tinyStar()
        #expect(InputImage(cgImage: img, maxDimension: 2000, minDimension: 256).upscale == 1)
        #expect(InputImage(cgImage: img, maxDimension: 2000, minDimension: 256, highDetail: true).upscale == 4)
        // Big images are upscaled less, so processing stays under ~6000 px.
        let big = Bitmap(width: 2500, height: 20) { x, _ in x % 7 < 3 ? RGBA(20, 40, 90) : RGBA(250, 250, 250) }
        #expect(InputImage(cgImage: big.makeCGImage(), maxDimension: 2000, minDimension: 256, highDetail: true).upscale == 2)
    }

    @Test func keepsTinyFeatures() throws {
        // The true star, and the traced result rendered at 8× around it: share of the star's
        // neighborhood where they disagree.
        let star = CGMutablePath()
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2, r = i % 2 == 0 ? 4.0 : 1.7
            let p = CGPoint(x: 150 + r * cos(a), y: 200 + r * sin(a))
            i == 0 ? star.move(to: p) : star.addLine(to: p)
        }
        star.closeSubpath()
        func mismatch(_ highDetail: Bool) throws -> Double {
            var o = Options(kind: .logo)
            o.highDetail = highDetail
            let r = try Vectorizer.vectorize(InputImage(cgImage: tinyStar(), maxDimension: 2000, minDimension: 256, highDetail: highDetail), options: o)
            let k = 8.0, n = 96   // 12 × 12 px window at 8×
            let traced = Bitmap.render(width: n, height: n) { ctx in
                ctx.scaleBy(x: k, y: k)
                ctx.translateBy(x: -144, y: -194)
                ShapeRenderer.fill(r.shapes, in: ctx)
            }
            var wrong = 0
            for y in 0..<n {
                for x in 0..<n {
                    let p = CGPoint(x: 144 + (Double(x) + 0.5) / k, y: 194 + (Double(y) + 0.5) / k)
                    let ink = traced[x, y].b < 180
                    if ink != star.contains(p) { wrong += 1 }
                }
            }
            return Double(wrong) / Double(n * n)
        }
        let normal = try mismatch(false), high = try mismatch(true)
        #expect(high < normal * 0.8, "mismatch: high detail \(high), normal \(normal)")
    }
}
