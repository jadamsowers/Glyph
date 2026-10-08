import CoreGraphics
import Foundation
import Testing
@testable import VectorEngine

@Suite struct PixelDetailTests {
    static let sprite = [
        "....KKKK....",
        "..KKRRRRKK..",
        ".KRRRWWRRRK.",
        ".KRRWWWWRRK.",
        "KRRRRWWRRRRK",
        "KRRRRRRRRRRK",
        "KKKKKKKKKKKK",
        "..KWWKKWWK..",
        "..KWWWWWWK..",
        "...KKKKKK...",
    ]

    // Hard-edged pixel art: detected, not upscaled, traced exactly.
    @Test func pixelArtSpriteTracesExactly() throws {
        let b = TestImages.grid(Self.sprite)
        let input = InputImage(cgImage: b.makeCGImage(), maxDimension: 2000, minDimension: 256)
        #expect(input.upscale == 1)
        let s = try Pipeline.run(input: input, options: Options())
        #expect(s.analysis?.isPixelArt == true)
        let r = try #require(s.result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: b.width, height: b.height, antialias: false)
        #expect(TestImages.agreement(raster, b) == 1)
        #expect(r.shapes.allSatisfy { $0.subpaths.allSatisfy { $0.segments.allSatisfy { if case .line = $0 { true } else { false } } } })
    }

    @Test func antialiasedImagesAreNotPixelArt() {
        for b in [TestImages.circle(size: 96, radius: 32, antialias: true), TestImages.outlinedIcon(), TestImages.photoLike()] {
            #expect(!Analyzer.analyze(b, params: ClassifierParams()).isPixelArt)
        }
    }

    // Regression (user's 62-px icon): mostly axis-aligned edges — identical with or without
    // anti-aliasing — plus an anti-aliased arrow and rounded corners. Not pixel art; upscaled.
    @Test func usersAntialiasedIconIsNotPixelArt() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/icon64.png")
        let image = try InputImage.orientedImage(contentsOf: url)
        #expect(!Analyzer.looksLikePixelArt(Bitmap(cgImage: image)))
        let input = InputImage(cgImage: image, maxDimension: 2000, minDimension: 256)
        #expect(input.upscale > 1)
        let s = try Pipeline.run(input: input, options: Options())
        #expect(s.resolved?.polygon.exactPixels == false)
        #expect(try #require(s.result).stats.segmentCount < 60)
    }

    @Test func exactPixelsCanBeTurnedOff() throws {
        let b = TestImages.grid(Self.sprite)
        var o = Options()
        o.exactPixels = false
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: b), options: o).result)
        #expect(r.shapes.contains { $0.subpaths.contains { $0.segments.contains { if case .cubic = $0 { true } else { false } } } })
    }

    /// A red anti-aliased rounded rect (large enough not to be upscaled) with a white notch of
    /// `width`×1 px cut into the middle of its top edge at integer coordinates (hard-edged).
    func notched(width: Int) -> Bitmap {
        Bitmap.render(width: 300, height: 200) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 40, y: 40, width: 220, height: 120), cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.15, blue: 0.2, alpha: 1)); ctx.fillPath()
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 150, y: 40, width: width, height: 1))
        }
    }

    func anchors(_ b: Bitmap, speck: Int) throws -> [Vec2] {
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: b), options: Options(kind: .logo, speckSize: speck)).result)
        let red = try #require(r.shapes.first { $0.color.r > 150 && $0.color.g < 100 })
        return red.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) }
    }

    // A 1-px notch is real detail: with a small speck size its four corners survive exactly.
    @Test func smallNotchSurvivesWithLowSpeckSize() throws {
        let pts = try anchors(notched(width: 6), speck: 1)
        for corner in [Vec2(150, 40), Vec2(156, 40), Vec2(150, 41), Vec2(156, 41)] {
            #expect(pts.map { $0.distance(to: corner) }.min()! < 0.3, "no anchor at notch corner \(corner)")
        }
    }

    // A notch smaller than the speck size is treated like a speck and smoothed away.
    @Test func notchBelowSpeckSizeIsSmoothed() throws {
        let pts = try anchors(notched(width: 2), speck: 4)
        #expect(!pts.contains { $0.distance(to: Vec2(150, 41)) < 0.3 || $0.distance(to: Vec2(152, 41)) < 0.3 })
    }
}
