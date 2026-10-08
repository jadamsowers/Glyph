import Testing
@testable import VectorEngine

@Suite struct RenderTests {
    @Test func everyStageRendersAtTheRequestedScale() throws {
        let s = try Pipeline.run(input: InputImage(bitmap: TestImages.circle(size: 32, radius: 10)), options: Options())
        for stage in Stage.allCases {
            let img = try #require(StageRenderer.image(for: stage, in: s, scale: 2), "\(stage)")
            #expect(img.width == 64 && img.height == 64, "\(stage)")
        }
    }

    @Test func stagesThatHaveNotRunRenderNil() {
        let s = PipelineState(input: InputImage(bitmap: TestImages.circle()), options: Options())
        #expect(StageRenderer.image(for: .curves, in: s) == nil)
    }

    @Test func falseColorsDifferBetweenNeighbors() {
        let seg = Segmenter.segment(TestImages.quantized(["RWB"]), params: SegmentParams(speckSize: 0))
        let b = StageRenderer.falseColor(seg)
        #expect(b[0, 0] != b[1, 0] && b[1, 0] != b[2, 0])
    }

    @Test func svgStageLooksLikeTheResult() throws {
        let s = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options())
        let img = try #require(StageRenderer.image(for: .svg, in: s))
        #expect(Bitmap(cgImage: img)[24, 24] == TestImages.red)
    }

    @Test func streamYieldsAllStagesThenFinishes() async throws {
        var stages: [Stage] = []
        var last: StageEvent?
        for try await e in Pipeline.stream(input: InputImage(bitmap: TestImages.circle()), options: Options()) {
            stages.append(e.stage)
            last = e
        }
        #expect(stages == Stage.allCases)
        #expect(last?.state.result != nil)
    }

    @Test func abandoningTheStreamEarlyIsSafe() async throws {
        for try await e in Pipeline.stream(input: InputImage(bitmap: TestImages.photoLike()), options: Options()) {
            #expect(e.stage == .analyze)
            break
        }
    }
}
