import Foundation
import Testing
@testable import VectorEngine

@Suite struct PipelineTests {
    func reusedStages(first: Options, then second: Options) throws -> [Stage] {
        let input = InputImage(bitmap: TestImages.circle())
        let previous = try Pipeline.run(input: input, options: first)
        var reused: [Stage] = []
        _ = try Pipeline.run(input: input, options: second, reusing: previous) { if $0.reused { reused.append($0.stage) } }
        return reused
    }

    @Test func logoEndToEnd() throws {
        let state = try Pipeline.run(input: InputImage(bitmap: TestImages.circle(antialias: true)), options: Options())
        let result = try #require(state.result)
        #expect(state.analysis?.kind == .logo)
        #expect(XMLParser(data: Data(result.svg.utf8)).parse())
        let raster = ShapeRenderer.rasterize(result.shapes, width: 48, height: 48, antialias: false, background: TestImages.magenta)
        #expect(!raster.pixels.contains(TestImages.magenta))
        #expect(TestImages.agreement(raster, try #require(state.quantized).makeBitmap()) > 0.95)
    }

    @Test func emitsEveryStageInOrder() throws {
        var seen: [Stage] = []
        _ = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options()) { seen.append($0.stage) }
        #expect(seen == Stage.allCases)
    }

    @Test func changingDetailReusesEverythingBeforePolygon() throws {
        #expect(try reusedStages(first: Options(), then: Options(detail: 0.9)) == [.analyze, .prefilter, .quantize, .segment, .contours])
    }

    @Test func changingTracingOnlyRedoesSVG() throws {
        #expect(try reusedStages(first: Options(), then: Options(tracing: .stacked)) == Array(Stage.allCases.dropLast()))
    }

    @Test func identicalOptionsReuseEverything() throws {
        #expect(try reusedStages(first: Options(), then: Options()) == Stage.allCases)
    }

    @Test func changingColorsRedoesFromQuantize() throws {
        #expect(try reusedStages(first: Options(), then: Options(colorCount: 5)) == [.analyze, .prefilter])
    }

    @Test func aDifferentInputIsNeverReused() throws {
        let previous = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options())
        var reused = 0
        _ = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options(), reusing: previous) { if $0.reused { reused += 1 } }
        #expect(reused == 0)
    }

    // Review focus: very large image.
    @Test func downscaledInputIsWrittenAtOriginalSize() throws {
        let big = Bitmap(width: 64, height: 48) { x, y in
            let dx = Double(x) - 32, dy = Double(y) - 24
            return dx * dx + dy * dy < 256 ? TestImages.red : TestImages.white
        }
        let input = InputImage(cgImage: big.makeCGImage(), maxDimension: 32)
        #expect(input.bitmap.width == 32 && input.bitmap.height == 24)
        let r = try Vectorizer.vectorize(input)
        #expect(r.width == 64 && r.height == 48)
        #expect(r.svg.contains("viewBox=\"0 0 64 48\""))
        let ends = r.shapes.flatMap { $0.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) } }
        #expect(ends.allSatisfy { $0.x >= 0 && $0.x <= 64 && $0.y >= 0 && $0.y <= 48 })
        #expect(ends.contains { $0.x > 40 })
    }

    @Test func throwingFromOnStageStopsTheRun() {
        #expect(throws: CancellationError.self) {
            try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options()) { _ in throw CancellationError() }
        }
    }
}
