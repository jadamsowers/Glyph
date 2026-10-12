import Foundation
import Testing
@testable import VectorEngine

@Suite struct BackgroundRemovalTests {
    typealias T = TestImages

    func solid(enclosed: Bool = true, tolerance: Double = 8, minEnclosedArea: Int = 4) -> BackgroundParams {
        BackgroundParams(method: .solid, tolerance: tolerance, removeEnclosed: enclosed, minEnclosedArea: minEnclosedArea)
    }

    /// A black "O" (ring) on white: the inside of the ring is an enclosed white area.
    func letterO(size: Int = 48) -> Bitmap {
        let c = Double(size) / 2
        return Bitmap(width: size, height: size) { x, y in
            let d = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot()
            return d <= 16 && d >= 9 ? T.black : T.white
        }
    }

    func opaqueCount(_ b: Bitmap) -> Int { b.pixels.filter { $0.a >= 128 }.count }

    @Test func removesEdgeColorAndEnclosedAreas() {
        let (out, outcome) = BackgroundRemover.remove(letterO(), solid())
        #expect(outcome == .solid(T.white))
        #expect(out[0, 0].a == 0 && out[47, 47].a == 0)     // background
        #expect(out[24, 24].a == 0)                         // inside of the O
        #expect(out[24, 11] == T.black)                     // the ring itself
    }

    @Test func enclosedAreasCanBeKept() {
        let (out, _) = BackgroundRemover.remove(letterO(), solid(enclosed: false))
        #expect(out[0, 0].a == 0)
        #expect(out[24, 24] == T.white)
    }

    @Test func enclosedAreasSmallerThanSpecksAreKept() {
        // A 2×2 white highlight inside a black square stays.
        var b = Bitmap(width: 32, height: 32) { x, y in (8..<24).contains(x) && (8..<24).contains(y) ? T.black : T.white }
        for y in 15...16 { for x in 15...16 { b[x, y] = T.white } }
        let (out, _) = BackgroundRemover.remove(b, solid(minEnclosedArea: 8))
        #expect(out[15, 15] == T.white && out[0, 0].a == 0)
    }

    @Test func toleranceAbsorbsNoise() {
        let b = T.noisy(T.circle(size: 48, radius: 14, fg: T.red, bg: T.white), amplitude: 6)
        let (out, outcome) = BackgroundRemover.remove(b, solid())
        guard case .solid = outcome else { Issue.record("expected solid, got \(outcome)"); return }
        let c = 24.0
        var leftover = 0, lost = 0
        for y in 0..<48 {
            for x in 0..<48 {
                let d = ((Double(x) + 0.5 - c) * (Double(x) + 0.5 - c) + (Double(y) + 0.5 - c) * (Double(y) + 0.5 - c)).squareRoot()
                if d > 16 && out[x, y].a >= 128 { leftover += 1 }
                if d < 12 && out[x, y].a < 128 { lost += 1 }
            }
        }
        #expect(leftover == 0 && lost == 0)
    }

    @Test func antialiasedEdgesKeepTheShapeSize() {
        let r = 16.0
        let (out, _) = BackgroundRemover.remove(T.circle(size: 48, radius: r, fg: T.red, bg: T.white, antialias: true), solid())
        let area = Double(opaqueCount(out)), expected = Double.pi * r * r
        #expect(abs(area - expected) / expected < 0.04, "area \(area) vs \(expected)")
    }

    @Test func mixedBorderRemovesNothing() {
        let b = T.randomBlocks(width: 24, height: 24, colors: [T.red, T.blue, T.green, T.white])
        let (out, outcome) = BackgroundRemover.remove(b, solid())
        #expect(outcome == .noDominantColor)
        #expect(out == b)
    }

    @Test func alreadyTransparentBorderIsLeftAlone() {
        let b = T.circle(size: 32, radius: 10, fg: T.red, bg: .clear)
        let (out, outcome) = BackgroundRemover.remove(b, solid())
        #expect(outcome == .alreadyTransparent && out == b)
    }

    @Test func subjectMaskBecomesAlpha() {
        let b = Bitmap(width: 4, height: 2) { _, _ in T.red }
        let mask: [Float] = [0, 0, 1, 1, 0, 0.25, 1, 1]
        let out = BackgroundRemover.applyMask(b, mask: mask)
        #expect(out[0, 0].a == 0 && out[2, 0].a == 255 && out[1, 1].a == 64)
    }

    @Test func subjectFallsBackToSolidWhenNoSubjectIsFound() {
        var p = solid()
        p.method = .subject
        let (out, outcome) = BackgroundRemover.remove(letterO(), p, subjectMask: { _ in nil })
        #expect(outcome == .subjectFallback(T.white))
        #expect(out[0, 0].a == 0 && out[24, 11] == T.black)
    }

    @Test func subjectUsesTheProvidedMask() {
        var p = solid()
        p.method = .subject
        let b = letterO()
        let (out, outcome) = BackgroundRemover.remove(b, p, subjectMask: { b in b.pixels.map { $0 == T.black ? 1 : 0 } })
        #expect(outcome == .subject)
        #expect(out[24, 24].a == 0 && out[24, 11] == T.black)
    }

    @Test func autoPicksSolidForLogosAndSubjectForPhotos() {
        #expect(BackgroundRemoval.Method.auto.resolved(for: .logo) == .solid)
        #expect(BackgroundRemoval.Method.auto.resolved(for: .photo) == .subject)
        #expect(BackgroundRemoval.Method.subject.resolved(for: .logo) == .subject)
    }

    @Test func pipelineTracesOnlyTheForeground() throws {
        var o = Options()
        o.removeBackground = BackgroundRemoval(method: .solid)
        let s = try Pipeline.run(input: InputImage(bitmap: letterO()), options: o)
        let r = try #require(s.result)
        #expect(r.stats.background == .solid(T.white))
        #expect(r.shapes.allSatisfy { $0.color != T.white })
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[0, 0].a == 0 && raster[24, 24].a == 0 && raster[24, 11].a == 255)
        // Off by default.
        #expect(try Pipeline.run(input: InputImage(bitmap: letterO()), options: Options()).result?.stats.background == nil)
    }

    @Test func invertedBlackAndWhiteKeepsRemovedBackgroundAsPaper() throws {
        // Light shape traced on a removed dark background: the background must not become ink.
        let b = T.circle(size: 48, radius: 14, fg: T.white, bg: T.black)
        var o = Options()
        o.monochrome = Monochrome(invert: true)
        o.removeBackground = BackgroundRemoval(method: .solid)
        let r = try #require(try Pipeline.run(input: InputImage(bitmap: b), options: o).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[24, 24].a == 255 && raster[1, 1].a == 0)
    }
}
