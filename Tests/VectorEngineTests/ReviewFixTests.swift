import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VectorEngine

@Suite struct ReviewFixTests {
    // Review #1: stacked mode must not paint over a transparent hole.
    @Test func stackedModeKeepsTransparentHolesOpen() throws {
        let donut = Bitmap(width: 40, height: 40) { x, y in
            let d = (pow(Double(x) + 0.5 - 20, 2) + pow(Double(y) + 0.5 - 20, 2)).squareRoot()
            return d >= 8 && d <= 15 ? TestImages.red : .clear
        }
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: donut), options: Options(tracing: .stacked)).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 40, height: 40, antialias: false)
        #expect(raster[20, 20].a == 0)
        #expect(raster[20, 8] == TestImages.red)
    }

    // Review #2: neighbouring (non-nested) shapes in stacked mode must not let the background
    // bleed through their shared edge when rendered with anti-aliasing.
    @Test func stackedSiblingsHaveNoSeams() throws {
        let b = Bitmap(width: 48, height: 32) { x, y in
            let wave = 16 + 6 * sin(Double(x) / 5)
            return Double(y) < wave ? TestImages.red : TestImages.blue
        }
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: b), options: Options(tracing: .stacked)).result)
        func worstAlpha(_ seam: Double) -> UInt8 {
            ShapeRenderer.rasterize(r.shapes, width: 48, height: 32, antialias: true, seamStroke: seam).pixels.map(\.a).min()!
        }
        #expect(r.seamStroke > 0)
        #expect(worstAlpha(0) < 220)               // without the underlay the seam shows
        #expect(worstAlpha(r.seamStroke) >= 240)   // with it, at most a few percent bleeds through
    }

    // Review #3: EXIF orientation must be applied (portrait phone photos).
    @Test func exifOrientationIsApplied() throws {
        let stored = Bitmap(width: 30, height: 10) { x, _ in x < 15 ? TestImages.red : TestImages.blue }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oriented-\(UUID()).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, stored.makeCGImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let input = try InputImage.load(contentsOf: url, maxDimension: 2000)
        #expect(input.originalWidth == 10 && input.originalHeight == 30)
        #expect(input.bitmap.width == 10 && input.bitmap.height == 30)
    }

    // Review #5: pure noise is not a logo.
    @Test func whiteNoiseIsPhoto() {
        var rng = SplitMix64(seed: 99)
        let noise = Bitmap(width: 96, height: 96) { _, _ in
            let v = rng.next()
            return RGBA(UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff))
        }
        #expect(Analyzer.analyze(noise, params: ClassifierParams()).kind == .photo)
    }
}
